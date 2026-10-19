/*
 * qidislice.cpp — implémentation de l'ABI C.
 *
 * v2 : le slicing passe par l'API objet de libslic3r (Print::apply/process/
 * export_gcode) et non plus par Slic3r::CLI::run(). C'est ce qui donne la
 * progression et l'annulation, et des erreurs structurées.
 *
 * Les API utilisées sont celles que le binaire desktop exerce déjà :
 *   Slic3r::FileReader::load_model        (libslic3r/FileReader.hpp)
 *   Slic3r::Print::apply / process        (libslic3r/Print.hpp)
 *   Slic3r::Print::export_gcode           (idem, utilisé par BackgroundSlicingProcess)
 *   Slic3r::PrintBase::set_status_callback / cancel / canceled (PrintBase.hpp)
 */
#include "qidislice.h"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "libslic3r/libslic3r.h"
#include "libslic3r/Utils.hpp"
#include "libslic3r/FileReader.hpp"
#include "libslic3r/Print.hpp"
#include "libslic3r/PrintConfig.hpp"
#include "libslic3r/GCode/ThumbnailData.hpp"
#include "libslic3r/BuildVolume.hpp"
#include "libslic3r/MultipleBeds.hpp"
#include "libslic3r/Model.hpp"
// Place les objets sur le plateau (wrapper fourni par la cible slic3r-arrange-wrapper,
// que la CLI amont utilise aussi).
#include <arrange-wrapper/ModelArrange.hpp>
#include "libslic3r_version.h" // généré par la compilation amont (SLIC3R_APP_NAME/VERSION)
// Slic3r::CLI::run() est déclaré dans QIDISlicer.hpp (pas dans CLI/CLI.hpp) :
// c'est le point d'entrée que le main() du binaire desktop appelle.
#include "QIDISlicer.hpp"

namespace {

std::string tail(const std::string &msg, size_t max = 480)
{
    return msg.size() <= max ? msg : "…" + msg.substr(msg.size() - max);
}

void set_err(char *err_msg, size_t err_len, const std::string &msg)
{
    if (!err_msg || err_len == 0)
        return;
    std::snprintf(err_msg, err_len, "%s", tail(msg).c_str());
}

/* Le cœur consomme un argv modifiable : buffers stables pendant tout l'appel. */
struct Argv {
    std::vector<std::string> storage;
    std::vector<char *>      ptrs;

    void push(const std::string &s) { storage.push_back(s); }

    int run(const char *prog)
    {
        storage.insert(storage.begin(), prog ? prog : "qidi-slicer");
        ptrs.clear();
        ptrs.reserve(storage.size() + 1);
        for (std::string &s : storage)
            ptrs.push_back(const_cast<char *>(s.c_str()));
        ptrs.push_back(nullptr);
        return Slic3r::CLI::run(static_cast<int>(storage.size()), ptrs.data());
    }
};

} // namespace

struct qsid_ctx {
    std::string resources_dir;
    std::string data_dir;
    std::string prog_name = "qidi-slicer";
    bool        initialized = false;

    /* Annulation : le drapeau est lu par le callback de statut et par
     * qsid_cancel(), qui peut appeler Print::cancel() directement. */
    std::atomic<bool>  cancel_requested{false};
    std::mutex         print_mutex;
    Slic3r::Print     *current_print = nullptr;

    /* Un seul slicing à la fois (libslic3r n'est pas réentrant). */
    std::atomic<bool>  slicing{false};
};

extern "C" {

qsid_ctx *qsid_create(const char *resources_dir, const char *data_dir)
{
    auto *ctx = new (std::nothrow) qsid_ctx();
    if (!ctx)
        return nullptr;

    if (resources_dir && *resources_dir) {
        Slic3r::set_resources_dir(resources_dir);
        ctx->resources_dir = resources_dir;
    }
    if (data_dir && *data_dir) {
        Slic3r::set_data_dir(data_dir);
        ctx->data_dir = data_dir;
    }
    ctx->initialized = true;
    return ctx;
}

void qsid_destroy(qsid_ctx *ctx)
{
    delete ctx;
}

int qsid_version(char *buf, size_t buflen)
{
    if (!buf || buflen == 0)
        return QSID_ERR_ARG;
    std::snprintf(buf, buflen, "%s %s", SLIC3R_APP_NAME, SLIC3R_VERSION);
    return QSID_OK;
}

void qsid_cancel(qsid_ctx *ctx)
{
    if (!ctx)
        return;
    ctx->cancel_requested.store(true);
    /* Annulation immédiate : Print::cancel() est conçu pour être appelé depuis
     * un autre thread (le GUI le fait depuis son thread principal). */
    std::lock_guard<std::mutex> lock(ctx->print_mutex);
    if (ctx->current_print)
        ctx->current_print->cancel();
}

int qsid_slice_async(qsid_ctx *ctx,
                     const char *model_path,
                     const char *config_path,
                     const char *out_gcode,
                     qsid_progress_cb cb, void *user,
                     char *err_msg, size_t err_len)
{
    if (!ctx || !ctx->initialized)
        return QSID_ERR_NO_CONTEXT;
    if (!model_path || !*model_path || !out_gcode || !*out_gcode)
        return QSID_ERR_ARG;

    bool expected = false;
    if (!ctx->slicing.compare_exchange_strong(expected, true))
        return QSID_ERR_BUSY;

    struct Guard {
        std::atomic<bool> &flag;
        ~Guard() { flag.store(false); }
    } guard{ctx->slicing};

    ctx->cancel_requested.store(false);
    std::remove(out_gcode);

    try {
        Slic3r::Print print;

        {
            std::lock_guard<std::mutex> lock(ctx->print_mutex);
            ctx->current_print = &print;
        }
        // Déclaré après `print` : détruit avant lui, sur tous les chemins (retours
        // anticipés, exceptions). Sans lui, qsid_cancel() pouvait appeler cancel()
        // sur un Print déjà détruit.
        struct PrintGuard {
            qsid_ctx *c;
            ~PrintGuard() {
                std::lock_guard<std::mutex> lock(c->print_mutex);
                c->current_print = nullptr;
            }
        } print_guard{ctx};

        print.set_status_callback([ctx, cb, user](const Slic3r::PrintBase::SlicingStatus &status) {
            if (ctx->cancel_requested.load(std::memory_order_relaxed))
                return; // l'annulation réelle est faite par qsid_cancel()
            if (cb)
                cb(status.percent, status.text.c_str(), user);
        });

        Slic3r::Model model = Slic3r::FileReader::load_model(model_path);

        Slic3r::DynamicPrintConfig config = Slic3r::DynamicPrintConfig::full_print_config();
        if (config_path && *config_path) {
            Slic3r::DynamicPrintConfig user_config;
            // Substitutions tolérées silencieusement (options inconnues d'une version
            // à l'autre), comme la CLI desktop.
            user_config.load_from_ini(config_path, Slic3r::ForwardCompatibilitySubstitutionRule::EnableSystemSilent);
            config.apply(user_config);
        }

        // apply() renvoie APPLY_STATUS_UNCHANGED / CHANGED / INVALIDATED : aucun
        // n'est une erreur (INVALIDATED = il faudra recalculer, ce que fait notre
        // process() juste après).
        // Préparation du modèle : même séquence que la CLI amont (qui est la
        // référence qui fonctionne). Sans elle, l'export G-code plantait sur un
        // contour dégénéré (ASan : set_object_range -> Polygon::douglas_peucker).
        {
            // 0) poser chaque objet sur le plateau (Z min = 0), comme la CLI amont
            //    (CLI/ProcessTransform.cpp). arrange_objects ne touche pas à Z : sans
            //    cela un STL décalé en Z s'imprime en l'air ou sous le plateau.
            for (Slic3r::ModelObject *mo : model.objects)
                mo->ensure_on_bed();

            // 1) placement sur le plateau (gère aussi plusieurs objets)
            const Slic3r::Vec2crd gap{ Slic3r::s_multiple_beds.get_bed_gap() };
            Slic3r::arr2::ArrangeBed      bed =
                Slic3r::arr2::to_arrange_bed(Slic3r::get_bed_shape(config), gap);
            Slic3r::arr2::ArrangeSettings arrange_cfg;
            arrange_cfg.set_distance_from_objects(Slic3r::min_object_distance(config));
            Slic3r::arrange_objects(model, bed, arrange_cfg);

            // 2) un extrudeur par volume (sinon les volumes n'en ont aucun)
            for (Slic3r::ModelObject *mo : model.objects)
                print.auto_assign_extruders(mo);

            // 3) état « dans/hors volume d'impression » + un seul plateau
            auto *bed_opt = dynamic_cast<const Slic3r::ConfigOptionPoints *>(config.option("bed_shape"));
            if (bed_opt != nullptr) {
                Slic3r::Pointfs bed_shape = bed_opt->values;
                Slic3r::BuildVolume build_volume(bed_shape, config.opt_float("max_print_height"));
                Slic3r::s_multiple_beds.update_build_volume(Slic3r::BoundingBoxf(bed_shape));
                model.update_print_volume_state(build_volume);
            }
        }

        Slic3r::MultipleBedsUtils::with_single_bed_model_fff(model, 0, [&print, &model, &config]() {
            print.apply(model, config);
        });

        if (const std::string validation = print.validate(); !validation.empty()) {
            set_err(err_msg, err_len, validation);
            return QSID_ERR_SLICE_FAILED;
        }
        if (print.empty()) {
            set_err(err_msg, err_len, "nothing to print: the model is empty or outside the print volume");
            return QSID_ERR_SLICE_FAILED;
        }

        if (ctx->cancel_requested.load()) {
            set_err(err_msg, err_len, "canceled");
            return QSID_ERR_CANCELED;
        }

        print.process();
        if (ctx->cancel_requested.load()) {
            set_err(err_msg, err_len, "canceled");
            return QSID_ERR_CANCELED;
        }

        // Liste de vignettes vide : l'app affiche son propre aperçu, et cela évite
        // tout chemin qui appellerait un callback nul (assertions désactivées en Release).
        Slic3r::ThumbnailsGeneratorCallback thumbnails = [](const Slic3r::ThumbnailsParams &) {
            return Slic3r::ThumbnailsList{};
        };
        print.export_gcode(out_gcode, nullptr /* GCodeProcessorResult */, thumbnails);

        if (FILE *f = std::fopen(out_gcode, "rb")) {
            std::fclose(f);
        } else {
            set_err(err_msg, err_len, "the core reported success but no G-code was written");
            return QSID_ERR_IO;
        }
        return QSID_OK;
    } catch (const Slic3r::CanceledException &) {
        set_err(err_msg, err_len, "canceled");
        return QSID_ERR_CANCELED;
    } catch (const std::exception &e) {
        set_err(err_msg, err_len, e.what());
        return QSID_ERR_SLICE_FAILED;
    }
}

int qsid_export_stl(qsid_ctx *ctx, const char *model_path, const char *out_stl,
                    char *err_msg, size_t err_len)
{
    if (!ctx || !ctx->initialized)
        return QSID_ERR_NO_CONTEXT;
    if (!model_path || !*model_path || !out_stl || !*out_stl)
        return QSID_ERR_ARG;

    std::remove(out_stl);

    Argv a;
    a.push("--export-stl");
    a.push("--output");
    a.push(out_stl);
    a.push(model_path);

    const int rc = a.run(ctx->prog_name.c_str());
    if (rc != 0) {
        set_err(err_msg, err_len, "STL export failed (core exit status " + std::to_string(rc) + ")");
        return QSID_ERR_SLICE_FAILED;
    }
    if (FILE *f = std::fopen(out_stl, "rb")) {
        std::fclose(f);
        return QSID_OK;
    }
    set_err(err_msg, err_len, "the core reported success but no STL was written");
    return QSID_ERR_IO;
}

int qsid_slice(qsid_ctx *ctx, const char *model_path, const char *config_path,
               const char *out_gcode, char *err_msg, size_t err_len)
{
    if (!ctx || !ctx->initialized)
        return QSID_ERR_NO_CONTEXT;
    if (!model_path || !*model_path || !out_gcode || !*out_gcode)
        return QSID_ERR_ARG;

    Argv a;
    if (!ctx->data_dir.empty()) {
        a.push("--datadir");
        a.push(ctx->data_dir);
    }
    if (config_path && *config_path) {
        a.push("--load");
        a.push(config_path);
    }
    a.push("--export-gcode");
    a.push("--output");
    a.push(out_gcode);
    a.push(model_path);

    const int rc = a.run(ctx->prog_name.c_str());
    if (rc != 0) {
        set_err(err_msg, err_len,
                std::string("slicing failed (core exit status ") + std::to_string(rc) + ")");
        return QSID_ERR_SLICE_FAILED;
    }
    if (FILE *f = std::fopen(out_gcode, "rb")) {
        std::fclose(f);
    } else {
        set_err(err_msg, err_len, "the core reported success but no G-code was written");
        return QSID_ERR_IO;
    }
    return QSID_OK;
}

int qsid_run_cli(qsid_ctx *ctx, int argc, const char *const *argv,
                 char *err_msg, size_t err_len)
{
    if (!ctx || !ctx->initialized)
        return QSID_ERR_NO_CONTEXT;
    if (argc < 0 || (argc > 0 && !argv))
        return QSID_ERR_ARG;

    Argv a;
    for (int i = 0; i < argc; ++i)
        a.push(argv[i]);

    const int rc = a.run(ctx->prog_name.c_str());
    if (rc != 0) {
        set_err(err_msg, err_len, "the slicing core returned a non-zero status");
        return QSID_ERR_SLICE_FAILED;
    }
    return QSID_OK;
}

} // extern "C"

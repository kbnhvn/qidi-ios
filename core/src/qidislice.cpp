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
        // Placement : on centre le modèle sur le plateau et on le pose sur le lit.
        // Sans cela, un STL importé reste à l'origine (constaté : cube imprimé au
        // coin, avec des coordonnées négatives). L'arrange complet (nesting de
        // plusieurs objets) viendra plus tard.
        {
            Slic3r::BoundingBoxf3 bbox;
            for (const Slic3r::ModelObject *obj : model.objects)
                for (size_t i = 0; i < obj->instances.size(); ++i)
                    bbox.merge(obj->instance_bounding_box(i));

            const Slic3r::Points bed = Slic3r::get_bed_shape(config);
            if (bbox.defined && !bed.empty()) {
                double minx = bed.front().x(), maxx = minx;
                double miny = bed.front().y(), maxy = miny;
                for (const Slic3r::Vec2d &p : bed) {
                    minx = std::min(minx, p.x());
                    maxx = std::max(maxx, p.x());
                    miny = std::min(miny, p.y());
                    maxy = std::max(maxy, p.y());
                }
                const Slic3r::Vec3d shift(
                    (minx + maxx) / 2.0 - (bbox.min.x() + bbox.max.x()) / 2.0,
                    (miny + maxy) / 2.0 - (bbox.min.y() + bbox.max.y()) / 2.0,
                    0.0);
                for (Slic3r::ModelObject *obj : model.objects)
                    obj->translate_instances(shift);
            }
            for (Slic3r::ModelObject *obj : model.objects)
                obj->ensure_on_bed(true);
        }

        // On part de la configuration *complète* (toutes les clés existent), puis on
        // applique le profil : c'est la séquence de la CLI. Indispensable ici :
        // GCodeGenerator::_do_export lit par exemple `binary_gcode` sans garde, et
        // déréférence un pointeur nul si la clé manque (SIGSEGV constaté).
        print.apply(model, config);

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

        {
            std::lock_guard<std::mutex> lock(ctx->print_mutex);
            ctx->current_print = nullptr;
        }

        if (FILE *f = std::fopen(out_gcode, "rb")) {
            std::fclose(f);
        } else {
            set_err(err_msg, err_len, "the core reported success but no G-code was written");
            return QSID_ERR_IO;
        }
        return QSID_OK;
    } catch (const Slic3r::CanceledException &) {
        std::lock_guard<std::mutex> lock(ctx->print_mutex);
        ctx->current_print = nullptr;
        set_err(err_msg, err_len, "canceled");
        return QSID_ERR_CANCELED;
    } catch (const std::exception &e) {
        std::lock_guard<std::mutex> lock(ctx->print_mutex);
        ctx->current_print = nullptr;
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

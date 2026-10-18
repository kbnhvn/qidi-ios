/*
 * qidislice.cpp — implémentation de l'ABI C (v1 : au-dessus de Slic3r::CLI).
 *
 * Pourquoi la CLI et pas directement l'API libslic3r : le binaire macOS livré
 * montre que `Slic3r::CLI::run(int, char**)` est un point d'entrée réel du même
 * exécutable que la GUI, utilisé tel quel par `main()`. C'est donc le chemin le
 * moins risqué pour un premier port : aucun sous-processus, appel direct dans le
 * processus de l'app.
 *
 * La v2 remplacera ce chemin par l'API objet (Slic3r::Model, Slic3r::Print,
 * GCodeGenerator) pour obtenir progression, annulation et messages d'erreur
 * structurés.
 */
#include "qidislice.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "libslic3r/libslic3r.h"
#include "libslic3r/Utils.hpp"
#include "libslic3r_version.h" // généré par la compilation amont (SLIC3R_APP_NAME/VERSION)
// Slic3r::CLI::run() est déclaré dans QIDISlicer.hpp (pas dans CLI/CLI.hpp) :
// c'est le point d'entrée que le main() du binaire desktop appelle.
#include "QIDISlicer.hpp"

namespace {

std::string join_err(const std::string &msg)
{
    // Les messages du cœur peuvent être longs ; on garde la fin, plus utile.
    constexpr size_t kMax = 480;
    if (msg.size() <= kMax)
        return msg;
    return "…" + msg.substr(msg.size() - kMax);
}

void set_err(char *err_msg, size_t err_len, const std::string &msg)
{
    if (!err_msg || err_len == 0)
        return;
    const std::string s = join_err(msg);
    std::snprintf(err_msg, err_len, "%s", s.c_str());
}

/*
 * Le cœur consomme un `argv` modifiable et peut toucher à argv[0].
 * On garde donc des buffers stables pendant tout l'appel.
 */
struct Argv {
    std::vector<std::string> storage;
    std::vector<char *>      ptrs;

    void push(const std::string &s)
    {
        storage.push_back(s);
        ptrs.push_back(nullptr); // rebâti après, pour survivre aux réallocations
    }

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

struct qsid_ctx_impl {
    std::string resources_dir;
    std::string data_dir;
    std::string prog_name = "qidi-slicer";
    bool        initialized = false;
};

} // namespace

struct qsid_ctx {
    qsid_ctx_impl impl;
};

extern "C" {

qsid_ctx *qsid_create(const char *resources_dir, const char *data_dir)
{
    auto *ctx = new (std::nothrow) qsid_ctx();
    if (!ctx)
        return nullptr;

    if (resources_dir && *resources_dir) {
        Slic3r::set_resources_dir(resources_dir);
        ctx->impl.resources_dir = resources_dir;
    }
    if (data_dir && *data_dir) {
        Slic3r::set_data_dir(data_dir);
        ctx->impl.data_dir = data_dir;
    }

    // Le cœur journalise dans un fichier si demandé, sinon sur la sortie standard
    // (qui disparaît sous iOS) : on reste sur le comportement par défaut.
    ctx->impl.initialized = true;
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

int qsid_run_cli(qsid_ctx *ctx, int argc, const char *const *argv,
                 char *err_msg, size_t err_len)
{
    if (!ctx || !ctx->impl.initialized)
        return QSID_ERR_NO_CONTEXT;
    if (argc < 0 || (argc > 0 && !argv))
        return QSID_ERR_ARG;

    Argv a;
    for (int i = 0; i < argc; ++i)
        a.push(argv[i]);

    const int rc = a.run(ctx->impl.prog_name.c_str());
    if (rc != 0)
        set_err(err_msg, err_len, "the slicing core returned a non-zero status");
    return rc == 0 ? QSID_OK : QSID_ERR_SLICE_FAILED;
}

int qsid_slice(qsid_ctx *ctx, const char *model_path, const char *config_path,
               const char *out_gcode, char *err_msg, size_t err_len)
{
    if (!ctx || !ctx->impl.initialized)
        return QSID_ERR_NO_CONTEXT;
    if (!model_path || !*model_path || !out_gcode || !*out_gcode)
        return QSID_ERR_ARG;

    Argv a;
    if (!ctx->impl.data_dir.empty()) {
        // --datadir : racine des ressources (profils). Le cœur y cherche aussi
        // ses configurations ; sous iOS il est fourni par le bundle.
        a.push("--datadir");
        a.push(ctx->impl.data_dir);
    }
    if (config_path && *config_path) {
        a.push("--load");
        a.push(config_path);
    }
    a.push("--export-gcode");
    a.push("--output");
    a.push(out_gcode);
    a.push(model_path);

    const int rc = a.run(ctx->impl.prog_name.c_str());
    if (rc != 0) {
        set_err(err_msg, err_len,
                std::string("slicing failed (core exit status ") + std::to_string(rc) + ")");
        return QSID_ERR_SLICE_FAILED;
    }

    // Le cœur peut retourner 0 sans avoir écrit de fichier (par ex. modèle vide).
    if (FILE *f = std::fopen(out_gcode, "rb")) {
        std::fclose(f);
    } else {
        set_err(err_msg, err_len, "the core reported success but no G-code was written");
        return QSID_ERR_IO;
    }
    return QSID_OK;
}

} // extern "C"

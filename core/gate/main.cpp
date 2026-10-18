/*
 * qidislice_gate — vérifie que le cœur slice réellement, sans GUI et sans
 * sous-processus. Utilisé par la CI (runner macOS hôte) et en local.
 *
 *   qidislice_gate <modele.stl|3mf> <config.ini> <sortie.gcode> [--min-layers N] [--legacy]
 *
 * Par défaut, le chemin utilisé est celui de l'app : qsid_slice_async() (API
 * objet libslic3r, progression + annulation). `--legacy` exerce la CLI (v1).
 *
 * Code de sortie 0 = G-code produit et cohérent. Toute autre valeur = échec,
 * avec la raison sur la sortie d'erreur.
 */
#include "qidislice.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <fstream>

namespace {

struct Stats {
    size_t lines      = 0;
    size_t moves      = 0; // lignes G0/G1
    size_t layers     = 0; // occurrences de LAYER_CHANGE
    double extrusion  = 0.0;
};

Stats scan(const std::string &path, bool &ok)
{
    Stats st;
    std::ifstream in(path);
    if (!in) {
        ok = false;
        return st;
    }
    std::string line;
    while (std::getline(in, line)) {
        ++st.lines;
        if (line.rfind("G0 ", 0) == 0 || line.rfind("G1 ", 0) == 0)
            ++st.moves;
        if (line.find("LAYER_CHANGE") != std::string::npos)
            ++st.layers;
        const size_t e = line.find("E");
        if (e != std::string::npos && (line.rfind("G1 ", 0) == 0))
            st.extrusion += std::strtod(line.c_str() + e + 1, nullptr);
    }
    ok = true;
    return st;
}

std::string env_or(const char *name, const std::string &fallback)
{
    const char *v = std::getenv(name);
    return (v && *v) ? std::string(v) : fallback;
}

void on_progress(int percent, const char *message, void *)
{
    static int last_decile = -1;
    const int decile = percent / 10;
    if (decile != last_decile) {
        last_decile = decile;
        std::printf("  progression : %3d %%  %s\n", percent, message ? message : "");
        std::fflush(stdout);
    }
}

} // namespace

int main(int argc, char **argv)
{
    if (argc < 4) {
        std::fprintf(stderr,
                     "usage: %s <model> <config.ini> <out.gcode> [--min-layers N] [--legacy]\n"
                     "       (config.ini peut être '-' pour utiliser les défauts du cœur)\n",
                     argv[0]);
        return 2;
    }

    const std::string model  = argv[1];
    const std::string config = argv[2];
    const std::string out    = argv[3];

    int  min_layers = 5;
    bool legacy     = false;
    for (int i = 4; i < argc; ++i) {
        if (std::strcmp(argv[i], "--min-layers") == 0 && i + 1 < argc)
            min_layers = std::atoi(argv[++i]);
        else if (std::strcmp(argv[i], "--legacy") == 0)
            legacy = true;
    }

    std::remove(out.c_str());

    char version[128] = {0};
    qsid_version(version, sizeof(version));
    std::printf("gate: core = %s\n", version);

    const std::string resources = env_or("QSID_RESOURCES_DIR", "");
    const std::string datadir   = env_or("QSID_DATA_DIR", "");

    qsid_ctx *ctx = qsid_create(resources.empty() ? nullptr : resources.c_str(),
                                datadir.empty() ? nullptr : datadir.c_str());
    if (!ctx) {
        std::fprintf(stderr, "gate: FAIL — qsid_create() a renvoyé NULL\n");
        return 3;
    }

    char err[512] = {0};
    int rc;
    if (legacy) {
        std::printf("gate: chemin v1 (Slic3r::CLI::run)\n");
        rc = qsid_slice(ctx, model.c_str(),
                        config == "-" ? nullptr : config.c_str(),
                        out.c_str(), err, sizeof(err));
    } else {
        std::printf("gate: chemin v2 (Print::process/export_gcode, progression)\n");
        rc = qsid_slice_async(ctx, model.c_str(),
                              config == "-" ? nullptr : config.c_str(),
                              out.c_str(), on_progress, nullptr, err, sizeof(err));
    }
    qsid_destroy(ctx);

    if (rc != QSID_OK) {
        std::fprintf(stderr, "gate: FAIL — slicing rc=%d : %s\n", rc, err);
        return 4;
    }

    bool ok = false;
    const Stats st = scan(out, ok);
    if (!ok) {
        std::fprintf(stderr, "gate: FAIL — G-code illisible : %s\n", out.c_str());
        return 5;
    }

    std::printf("gate: %s\n", out.c_str());
    std::printf("gate: %zu lignes, %zu mouvements, %zu couches, extrusion %.1f mm\n",
                st.lines, st.moves, st.layers, st.extrusion);

    if (st.moves < 10) {
        std::fprintf(stderr, "gate: FAIL — trop peu de mouvements (%zu)\n", st.moves);
        return 6;
    }
    if (st.layers < static_cast<size_t>(min_layers)) {
        std::fprintf(stderr, "gate: FAIL — %zu couches < %d attendues\n", st.layers, min_layers);
        return 7;
    }
    if (st.extrusion <= 0.0) {
        std::fprintf(stderr, "gate: FAIL — aucune extrusion (le modèle n'a pas été slicé ?)\n");
        return 8;
    }

    std::printf("gate: OK\n");
    return 0;
}

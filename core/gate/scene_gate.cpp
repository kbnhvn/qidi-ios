/*
 * qidislice_scene_gate — exerce l'ABI v3 (presets, configuration, scène,
 * slicing incrémental, mouvements) contre le vrai moteur et le vrai bundle QIDI.
 *
 *   qidislice_scene_gate <QIDITechnology.ini> <cube.stl> <cube_z30.stl> <sortie_dir>
 *
 * Code de sortie 0 = toutes les vérifications passent.
 */
#include "qidislice.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <set>
#include <string>
#include <vector>

namespace {

int g_failures = 0;

void check(bool ok, const std::string &label, const std::string &detail = "")
{
    std::printf("  %-62s %s\n", label.c_str(), ok ? "ok" : ("ÉCHEC " + detail).c_str());
    if (!ok)
        ++g_failures;
}

bool contains(const std::string &hay, const std::string &needle)
{
    return hay.find(needle) != std::string::npos;
}

/* Premier nombre après `key` (ex. "\"filament_g\":"). NaN si absent. */
double number_after(const std::string &json, const std::string &key, size_t from = 0)
{
    const size_t p = json.find(key, from);
    if (p == std::string::npos)
        return std::nan("");
    return std::strtod(json.c_str() + p + key.size(), nullptr);
}

/* Les trois premiers nombres du premier tableau après `key`. */
bool vec3_after(const std::string &json, const std::string &key, double out[3], size_t from = 0)
{
    size_t p = json.find(key, from);
    if (p == std::string::npos)
        return false;
    p = json.find('[', p + key.size());
    if (p == std::string::npos)
        return false;
    ++p;
    char *end = nullptr;
    for (int i = 0; i < 3; ++i) {
        out[i] = std::strtod(json.c_str() + p, &end);
        p = static_cast<size_t>(end - json.c_str()) + 1;
    }
    return true;
}

std::string take(char *p)
{
    std::string s = p ? p : "";
    qsid_free(p);
    return s;
}

uint64_t first_id(const std::string &added_json)
{
    const size_t p = added_json.find("\"added\":[");
    return p == std::string::npos ? 0 : std::strtoull(added_json.c_str() + p + 9, nullptr, 10);
}

} // namespace

/* Fournisseur de vignettes factice : damier (remplit RGBA, lignes de haut en bas). */
static int g_thumb_calls = 0;
static int checker_provider(int w, int h, uint8_t *rgba, void *user)
{
    ++g_thumb_calls;
    (void) user;
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            const bool on = ((x / 16) + (y / 16)) % 2 == 0;
            uint8_t *p = rgba + (static_cast<size_t>(y) * w + x) * 4;
            p[0] = on ? 250 : 40; p[1] = on ? 175 : 40; p[2] = on ? 60 : 40; p[3] = 255;
        }
    return 1;
}

int main(int argc, char **argv)
{
    if (argc < 5) {
        std::fprintf(stderr, "usage: %s <QIDITechnology.ini> <cube.stl> <cube_z30.stl> <out_dir>\n", argv[0]);
        return 2;
    }
    const std::string vendor = argv[1], cube = argv[2], cube_z30 = argv[3], outdir = argv[4];
    char err[512] = {0};

    qsid_ctx *ctx = qsid_create(nullptr, nullptr);
    if (!ctx) {
        std::fprintf(stderr, "qsid_create a échoué\n");
        return 3;
    }

    std::printf("presets\n");
    check(qsid_presets_load(ctx, vendor.c_str(), err, sizeof(err)) == QSID_OK, "chargement du bundle vendor", err);
    char *json = nullptr;
    check(qsid_presets_list(ctx, "printer", &json, err, sizeof(err)) == QSID_OK, "liste des imprimantes");
    std::string printers = take(json);
    check(contains(printers, "\"Q2 0.4 nozzle\""), "Q2 0.4 nozzle listée");
    size_t commas = 0;
    for (char c : printers) commas += (c == ',');
    check(commas + 1 == 24, "24 imprimantes", std::to_string(commas + 1));

    check(qsid_presets_select(ctx, "Q2 0.4 nozzle", nullptr, nullptr, &json, err, sizeof(err)) == QSID_OK,
          "sélection imprimante seule", err);
    std::string sel = take(json);
    std::printf("    -> %s\n", sel.c_str());
    check(!contains(sel, "\"print\":\"- default -\"") && contains(sel, "@Q2 0.4 nozzle\""),
          "un preset d'impression concret et compatible est choisi (pas « - default - »)", sel);
    check(contains(sel, "\"print\":\"0.20mm"), "épaisseur ≈ moitié de la buse par défaut", sel);
    check(contains(sel, "\"filament\":\"") && contains(sel, "@Q2 0.4 nozzle\"}"),
          "un filament de la bonne variante de buse est choisi", sel);

    // Le filament d'une autre buse est refusé et remplacé par un compatible.
    check(qsid_presets_list(ctx, "filament", &json, err, sizeof(err)) == QSID_OK, "liste des filaments compatibles");
    std::string filaments = take(json);
    check(contains(filaments, "@Q2 0.4 nozzle\""), "filaments @Q2 0.4 proposés", filaments.substr(0, 200));
    check(qsid_presets_list(ctx, "print", &json, err, sizeof(err)) == QSID_OK, "liste des impressions compatibles");
    std::string prints = take(json);
    check(!contains(prints, "@Q2 0.6 nozzle") && contains(prints, "@Q2 0.4 nozzle"),
          "impressions filtrées par la buse", prints.substr(0, 200));

    std::printf("configuration\n");
    check(qsid_config_base(ctx, &json) == QSID_OK, "config du preset");
    std::string base = take(json);
    check(contains(base, "\"use_relative_e_distances\":\"1\""), "extrusion relative (profils QIDI)");
    check(contains(base, "\"gcode_flavor\":\"klipper\""), "G-code Klipper");
    check(qsid_config_set(ctx, "fill_density", "25%", err, sizeof(err)) == QSID_OK, "surcharge fill_density=25%", err);
    check(qsid_config_set(ctx, "fill_density", "abc", err, sizeof(err)) == QSID_ERR_ARG, "valeur invalide refusée");
    check(qsid_config_set(ctx, "no_such_option", "1", err, sizeof(err)) == QSID_ERR_ARG, "option inconnue refusée");
    check(qsid_config_overrides(ctx, &json) == QSID_OK, "liste des surcharges");
    check(contains(take(json), "\"fill_density\":\"25%\""), "surcharge enregistrée");
    check(qsid_config_effective(ctx, &json) == QSID_OK, "config effective");
    check(contains(take(json), "\"fill_density\":\"25%\""), "surcharge visible dans la config effective");
    // Une valeur égale à celle du preset retire la surcharge.
    std::string preset_density = base.substr(base.find("\"fill_density\":\"") + 16);
    preset_density = preset_density.substr(0, preset_density.find('"'));
    check(qsid_config_set(ctx, "fill_density", preset_density.c_str(), err, sizeof(err)) == QSID_OK, "retour à la valeur du preset");
    check(qsid_config_overrides(ctx, &json) == QSID_OK && take(json) == "{}", "surcharge retirée");
    check(qsid_config_schema(ctx, &json) == QSID_OK, "schéma des options");
    std::string schema = take(json);
    check(contains(schema, "\"key\":\"fill_density\"") && contains(schema, "\"mode\":\"simple\""),
          "schéma : fill_density (simple)");
    check(contains(schema, "\"key\":\"gcode_flavor\"") && contains(schema, "\"enum_values\""), "schéma : énumérations");
    std::printf("    schéma : %zu octets\n", schema.size());

    std::printf("scène\n");
    check(qsid_scene_add(ctx, cube.c_str(), &json, err, sizeof(err)) == QSID_OK, "import du cube", err);
    std::string added = take(json);
    const uint64_t id1 = first_id(added);
    check(id1 != 0, "identifiant d'objet");
    check(qsid_scene_info(ctx, &json) == QSID_OK, "état de la scène");
    std::string info = take(json);
    double off[3] = {0, 0, 0};
    check(vec3_after(info, "\"offset\":", off), "offset d'instance");
    std::printf("    offset = %.1f, %.1f, %.1f\n", off[0], off[1], off[2]);
    check(contains(info, "\"outside\":false"), "objet dans le volume d'impression");
    double zmin[3] = {1, 1, 1};
    vec3_after(info, "\"min\":", zmin);
    check(std::fabs(zmin[2]) < 1e-4, "posé sur le plateau (Z min = 0)", std::to_string(zmin[2]));

    // Un fichier décalé en Z est posé sur le plateau.
    check(qsid_scene_add(ctx, cube_z30.c_str(), &json, err, sizeof(err)) == QSID_OK, "import du cube décalé en Z", err);
    std::string added2 = take(json);
    const uint64_t id2 = first_id(added2);
    check(qsid_scene_info(ctx, &json) == QSID_OK, "état de la scène (2 objets)");
    info = take(json);
    const size_t second = info.find("\"id\":" + std::to_string(id2));
    double zmin2[3] = {1, 1, 1}, max1[3], min1[3], min2[3], max2[3];
    vec3_after(info, "\"min\":", zmin2, second);
    check(std::fabs(zmin2[2]) < 1e-4, "cube décalé en Z : posé sur le plateau", std::to_string(zmin2[2]));
    vec3_after(info, "\"min\":", min1);
    vec3_after(info, "\"max\":", max1);
    vec3_after(info, "\"min\":", min2, second);
    vec3_after(info, "\"max\":", max2, second);
    const bool overlap = min1[0] < max2[0] && max1[0] > min2[0] && min1[1] < max2[1] && max1[1] > min2[1];
    check(!overlap, "les deux objets ne se chevauchent pas");

    std::printf("manipulation\n");
    const double pos[3] = {50, 60, 0};
    check(qsid_scene_set_transform(ctx, id1, 0, pos, nullptr, nullptr, 1) == QSID_OK, "déplacement de l'objet 1");
    const double rot[3] = {0, 0, 90};
    check(qsid_scene_set_transform(ctx, id1, 0, nullptr, rot, nullptr, 1) == QSID_OK, "rotation Z 90°");
    const double bad_scale[3] = {0, 1, 1};
    check(qsid_scene_set_transform(ctx, id1, 0, nullptr, nullptr, bad_scale, 0) == QSID_ERR_ARG, "échelle nulle refusée");
    const double tilt[3] = {35, 20, 10};
    check(qsid_scene_set_transform(ctx, id2, 0, nullptr, tilt, nullptr, 1) == QSID_OK, "objet 2 incliné");
    check(qsid_scene_lay_on_face(ctx, id2, 0, 0, err, sizeof(err)) == QSID_OK, "poser sur la face 0", err);
    check(qsid_scene_info(ctx, &json) == QSID_OK, "état après pose");
    info = take(json);
    const size_t s2 = info.find("\"id\":" + std::to_string(id2));
    double zmin3[3] = {1, 1, 1};
    vec3_after(info, "\"min\":", zmin3, s2);
    check(std::fabs(zmin3[2]) < 1e-3, "après « poser sur une face » : Z min = 0", std::to_string(zmin3[2]));
    check(qsid_scene_set_instances(ctx, id1, 3) == QSID_OK, "3 instances de l'objet 1");
    check(qsid_scene_set_instances(ctx, id1, 1) == QSID_OK, "retour à 1 instance");

    float *tris = nullptr;
    size_t ntri = 0;
    check(qsid_scene_mesh(ctx, id1, &tris, &ntri, err, sizeof(err)) == QSID_OK && ntri == 12, "maillage local : 12 triangles",
          std::to_string(ntri));
    qsid_free(tris);

    std::printf("vignettes (fournisseur de l'hôte)\n");
    {
        // X-Plus 4 : « 272x272/PNG, 96x96/PNG » dans le bundle QIDI
        check(qsid_presets_select(ctx, "X-Plus 4 0.4 nozzle", nullptr, nullptr, &json, err, sizeof(err)) == QSID_OK,
              "imprimante X-Plus 4", err);
        qsid_free(json);
        qsid_set_thumbnail_provider(ctx, checker_provider, nullptr);
        check(qsid_scene_set_transform(ctx, id1, 0, pos, nullptr, nullptr, 1) == QSID_OK, "objet remis dans le plateau (plateau 280)");
        char *s2 = nullptr;
        const int rc_thumb = qsid_slice_scene(ctx, (outdir + "/thumb.gcode").c_str(), nullptr, nullptr, &s2, err, sizeof(err));
        qsid_free(s2);
        check(rc_thumb == QSID_OK, "slicing avec fournisseur de vignettes", err);
        check(g_thumb_calls >= 2, "le moteur a demandé les 2 tailles", std::to_string(g_thumb_calls));
        std::ifstream in(outdir + "/thumb.gcode");
        std::string line;
        int begins = 0;
        bool size272 = false, size96 = false;
        while (std::getline(in, line))
            if (line.find("thumbnail begin") != std::string::npos) {
                ++begins;
                size272 = size272 || line.find("272x272") != std::string::npos;
                size96 = size96 || line.find("96x96") != std::string::npos;
            }
        check(begins == 2 && size272 && size96, "deux vignettes (272 et 96) écrites dans le G-code", std::to_string(begins));
        qsid_set_thumbnail_provider(ctx, nullptr, nullptr);
        // retour à la Q2 pour la suite
        qsid_presets_select(ctx, "Q2 0.4 nozzle", nullptr, nullptr, &json, err, sizeof(err));
        qsid_free(json);
    }

    std::printf("slicing de la scène\n");
    const std::string gcode = outdir + "/scene.gcode";
    char *summary = nullptr;
    int rc = qsid_slice_scene(ctx, gcode.c_str(), nullptr, nullptr, &summary, err, sizeof(err));
    check(rc == QSID_OK, "slicing (objets déplacés/tournés)", err);
    std::string sum = take(summary);
    std::printf("    %s\n", sum.substr(0, 400).c_str());
    check(number_after(sum, "\"time_normal_s\":") > 10, "durée estimée");
    check(number_after(sum, "\"filament_g\":") > 0.1, "filament estimé (g)");
    check(number_after(sum, "\"layers\":") >= 20, "nombre de couches");

    qsid_move *moves = nullptr;
    size_t nmoves = 0;
    check(qsid_gcode_moves(ctx, &moves, &nmoves) == QSID_OK && nmoves > 1000, "mouvements disponibles", std::to_string(nmoves));
    // L'objet 1 est centré en (50, 60) après rotation de 90° : on doit extruder autour.
    size_t near1 = 0, extrude = 0;
    for (size_t i = 0; i < nmoves; ++i)
        if (moves[i].type == 10) {
            ++extrude;
            if (std::fabs(moves[i].x - 50) < 11 && std::fabs(moves[i].y - 60) < 11)
                ++near1;
        }
    check(extrude > 500, "mouvements d'extrusion", std::to_string(extrude));
    check(near1 > 100, "l'objet 1 est imprimé là où on l'a déplacé", std::to_string(near1));
    qsid_free(moves);
    qsid_release_result(ctx);
    qsid_move *none = nullptr;
    size_t nnone = 99;
    check(qsid_gcode_moves(ctx, &none, &nnone) == QSID_OK && nnone == 0 && none == nullptr,
          "mouvements libérés par qsid_release_result");

    std::printf("re-slicing après changement de réglage\n");
    check(qsid_config_set(ctx, "fill_density", "40%", err, sizeof(err)) == QSID_OK, "fill_density=40%");
    summary = nullptr;
    rc = qsid_slice_scene(ctx, (outdir + "/scene2.gcode").c_str(), nullptr, nullptr, &summary, err, sizeof(err));
    check(rc == QSID_OK, "second slicing (Print conservé)", err);
    std::string sum2 = take(summary);
    check(number_after(sum2, "\"filament_g\":") > number_after(sum, "\"filament_g\":"),
          "plus de remplissage = plus de filament");

    // ---- calibration : mêmes recettes que Plater::calib_pa_tower / calib_flowrate_coarse
    if (const char *calib = std::getenv("QSID_CALIB_DIR")) {
        std::printf("calibration\n");
        const std::string dir = calib;
        check(qsid_scene_clear(ctx) == QSID_OK, "scène vidée");
        check(qsid_scene_add(ctx, (dir + "/PressureAdvance/pa_tower.stl").c_str(), &json, err, sizeof(err)) == QSID_OK,
              "tour PA importée", err);
        const uint64_t tower = first_id(take(json));
        check(qsid_scene_info(ctx, &json) == QSID_OK, "état (tour)");
        std::string tinfo = take(json);
        double lmin[3] = {0}, lmax[3] = {0};
        vec3_after(tinfo, "\"local_min\":", lmin);
        vec3_after(tinfo, "\"local_max\":", lmax);
        const double target = 21 * 5.0;   // 0 -> 0.04 par pas de 0.002 : 20 pas, 21 marches
        const double sz[3] = {1, 1, target / (lmax[2] - lmin[2])};
        check(qsid_scene_set_transform(ctx, tower, 0, nullptr, nullptr, sz, 1) == QSID_OK, "tour mise à la hauteur", "");
        check(qsid_config_set(ctx, "before_layer_gcode", "M900 K{int(layer_z / 5) * 0.002 + 0}\n", err, sizeof(err)) == QSID_OK,
              "before_layer_gcode (M900 K…)", err);
        summary = nullptr;
        rc = qsid_slice_scene(ctx, (outdir + "/pa.gcode").c_str(), nullptr, nullptr, &summary, err, sizeof(err));
        check(rc == QSID_OK, "slicing de la tour PA", err);
        qsid_free(summary);
        std::set<std::string> ks;
        double last = -1;
        bool increasing = true;
        {
            std::ifstream in(outdir + "/pa.gcode");
            std::string line;
            bool started = false;   // le start-gcode du preset contient déjà un « M900 K… »
            while (std::getline(in, line)) {
                if (line.rfind(";LAYER_CHANGE", 0) == 0) started = true;
                if (started && line.rfind("M900 K", 0) == 0) {
                    ks.insert(line);
                    const double k = std::strtod(line.c_str() + 6, nullptr);
                    if (k + 1e-9 < last) increasing = false;
                    last = k;
                }
            }
        }
        check(ks.size() >= 15, "M900 K émis par marche", std::to_string(ks.size()));
        check(increasing, "valeurs de K croissantes");
        check(std::fabs(last - 0.04) < 0.0025, "dernière valeur ≈ 0.04", std::to_string(last));
        check(qsid_config_reset(ctx, nullptr) == QSID_OK, "réglages restaurés");

        check(qsid_scene_clear(ctx) == QSID_OK, "scène vidée (débit)");
        rc = qsid_scene_add(ctx, (dir + "/FlowRate/flowrate_coarse.3mf").c_str(), &json, err, sizeof(err));
        check(rc == QSID_OK, "flowrate_coarse.3mf importé", err);
        std::string flow = take(json);
        check(qsid_config_set(ctx, "complete_objects", "1", err, sizeof(err)) == QSID_OK, "complete_objects", err);
        check(qsid_config_set(ctx, "extruder_clearance_radius", "1", err, sizeof(err)) == QSID_OK, "extruder_clearance_radius", err);
        check(qsid_config_set(ctx, "between_objects_gcode", "M221 S{120 - 5 * current_object_idx}", err, sizeof(err)) == QSID_OK,
              "between_objects_gcode", err);
        check(qsid_scene_info(ctx, &json) == QSID_OK, "état (débit)");
        std::string finfo = take(json);
        size_t nobj = 0;
        for (size_t p = finfo.find("\"name\""); p != std::string::npos; p = finfo.find("\"name\"", p + 1)) ++nobj;
        check(nobj >= 5, "plusieurs objets dans le 3MF de débit", std::to_string(nobj));
        check(!contains(finfo, "\"outside\":true"), "tous dans le volume d'impression");
        summary = nullptr;
        rc = qsid_slice_scene(ctx, (outdir + "/flow.gcode").c_str(), nullptr, nullptr, &summary, err, sizeof(err));
        check(rc == QSID_OK, "slicing du débit grossier (impression séquentielle)", err);
        qsid_free(summary);
        size_t m221 = 0;
        {
            std::ifstream in(outdir + "/flow.gcode");
            std::string line;
            while (std::getline(in, line)) if (line.rfind("M221 S", 0) == 0) ++m221;
        }
        check(m221 >= nobj - 1, "M221 entre les objets", std::to_string(m221));
        qsid_config_reset(ctx, nullptr);
    }

    std::printf("scène vide\n");
    check(qsid_scene_clear(ctx) == QSID_OK, "scène vidée");
    rc = qsid_slice_scene(ctx, (outdir + "/empty.gcode").c_str(), nullptr, nullptr, nullptr, err, sizeof(err));
    check(rc == QSID_ERR_SLICE_FAILED, "scène vide : erreur claire", err);

    qsid_destroy(ctx);
    std::printf(g_failures ? "scene gate: %d ÉCHEC(S)\n" : "scene gate: OK\n", g_failures);
    return g_failures ? 1 : 0;
}

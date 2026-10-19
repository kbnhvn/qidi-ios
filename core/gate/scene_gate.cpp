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
    p += key.size();
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
    check(contains(sel, "@Q2 0.4 nozzle\"") || contains(sel, "Q2"), "impression compatible choisie par le moteur");
    check(!contains(sel, "\"filament\":\"\""), "un filament compatible est choisi");

    // Le filament d'une autre buse est refusé et remplacé par un compatible.
    check(qsid_presets_list(ctx, "filament", &json, err, sizeof(err)) == QSID_OK, "liste des filaments compatibles");
    std::string filaments = take(json);
    check(!contains(filaments, "@Q2 0.6 nozzle"), "aucun filament @Q2 0.6 pour une buse 0.4", filaments.substr(0, 200));
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

    std::printf("re-slicing après changement de réglage\n");
    check(qsid_config_set(ctx, "fill_density", "40%", err, sizeof(err)) == QSID_OK, "fill_density=40%");
    summary = nullptr;
    rc = qsid_slice_scene(ctx, (outdir + "/scene2.gcode").c_str(), nullptr, nullptr, &summary, err, sizeof(err));
    check(rc == QSID_OK, "second slicing (Print conservé)", err);
    std::string sum2 = take(summary);
    check(number_after(sum2, "\"filament_g\":") > number_after(sum, "\"filament_g\":"),
          "plus de remplissage = plus de filament");

    std::printf("scène vide\n");
    check(qsid_scene_clear(ctx) == QSID_OK, "scène vidée");
    rc = qsid_slice_scene(ctx, (outdir + "/empty.gcode").c_str(), nullptr, nullptr, nullptr, err, sizeof(err));
    check(rc == QSID_ERR_SLICE_FAILED, "scène vide : erreur claire", err);

    qsid_destroy(ctx);
    std::printf(g_failures ? "scene gate: %d ÉCHEC(S)\n" : "scene gate: OK\n", g_failures);
    return g_failures ? 1 : 0;
}

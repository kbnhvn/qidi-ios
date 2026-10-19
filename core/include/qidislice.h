/*
 * qidislice.h — ABI C étroite autour du cœur de slicing QIDISlicer (libslic3r)
 * pour l'app iPadOS.
 *
 * Objectif : permettre à Swift (ou à tout autre hôte) de slicer *dans le
 * processus*, sans interface graphique et sans lancer de sous-processus
 * (interdits sous iOS).
 *
 * Contrat :
 *   - `qsid_slice_async()` est bloquant mais *rapporte la progression* et peut
 *     être annulé depuis un autre thread (`qsid_cancel()`).
 *   - tous les appels sont sérialisés : un seul slicing à la fois par contexte
 *     (libslic3r n'est pas réentrant).
 *   - les chemins sont en UTF-8.
 */
#ifndef QIDISLICE_H
#define QIDISLICE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  define QSID_EXPORT __declspec(dllexport)
#else
#  define QSID_EXPORT __attribute__((visibility("default")))
#endif

/* Contexte opaque. Créé une fois au démarrage de l'app. */
typedef struct qsid_ctx qsid_ctx;

/* Codes de retour communs. */
enum {
    QSID_OK                = 0,
    QSID_ERR_ARG           = 1,  /* argument invalide                              */
    QSID_ERR_NO_CONTEXT    = 2,  /* contexte nul / non initialisé                   */
    QSID_ERR_IO            = 3,  /* fichier absent ou illisible                     */
    QSID_ERR_SLICE_FAILED  = 4,  /* le cœur a échoué (voir err_msg)                 */
    QSID_ERR_CANCELED      = 5,  /* annulé via qsid_cancel()                        */
    QSID_ERR_BUSY          = 6   /* un slicing est déjà en cours sur ce contexte    */
};

/*
 * Progression. Appelée depuis le thread de slicing, plusieurs fois par seconde.
 * `percent` va de 0 à 100 (ou -1 si inconnu) ; `message` est en UTF-8 et ne vit
 * que le temps de l'appel. L'hôte doit replanifier sur son thread principal.
 */
typedef void (*qsid_progress_cb)(int percent, const char *message, void *user);

/*
 * Crée un contexte.
 *   resources_dir : racine des ressources QIDISlicer dans le bundle (lecture seule).
 *   data_dir      : répertoire inscriptible (conteneur de l'app).
 * Retourne NULL si l'initialisation échoue. Un seul contexte par processus.
 */
QSID_EXPORT qsid_ctx *qsid_create(const char *resources_dir, const char *data_dir);

/* Libère le contexte (à n'appeler qu'en fin de vie de l'app). */
QSID_EXPORT void qsid_destroy(qsid_ctx *ctx);

/* Version du cœur, ex. "QIDISlicer 1.2.5". */
QSID_EXPORT int qsid_version(char *buf, size_t buflen);

/*
 * Slice `model_path` (STL, 3MF, OBJ, AMF) vers `out_gcode`, via l'API objet
 * libslic3r (Print::process + export_gcode). Bloquant ; progression via `cb` ;
 * interruption via qsid_cancel() depuis un autre thread.
 *
 *   config_path : fichier .ini de configuration (format PrusaSlicer/QIDISlicer).
 *                 Peut être NULL : les valeurs par défaut du cœur sont alors
 *                 utilisées — ce n'est PAS un profil d'imprimante utilisable.
 */
QSID_EXPORT int qsid_slice_async(qsid_ctx *ctx,
                                 const char *model_path,
                                 const char *config_path,
                                 const char *out_gcode,
                                 qsid_progress_cb cb, void *user,
                                 char *err_msg, size_t err_len);

/*
 * Demande l'annulation du slicing en cours. Thread-safe, sans effet si rien ne
 * tourne. `qsid_slice_async()` renvoie alors QSID_ERR_CANCELED.
 */
QSID_EXPORT void qsid_cancel(qsid_ctx *ctx);

/*
 * Exporte un modèle vers un STL binaire (utile au visualiseur : un 3MF/OBJ/AMF
 * devient un STL que l'app peut afficher). Utilise la CLI du cœur (in-process).
 */
QSID_EXPORT int qsid_export_stl(qsid_ctx *ctx,
                                const char *model_path,
                                const char *out_stl,
                                char *err_msg, size_t err_len);

/*
 * v1 conservées : appel direct de Slic3r::CLI::run() (sans progression), et
 * slicing synchrone qui en dépend. Utiles pour `--query-printer-models` & co.
 */
QSID_EXPORT int qsid_slice(qsid_ctx *ctx,
                           const char *model_path,
                           const char *config_path,
                           const char *out_gcode,
                           char *err_msg, size_t err_len);

QSID_EXPORT int qsid_run_cli(qsid_ctx *ctx,
                             int argc, const char *const *argv,
                             char *err_msg, size_t err_len);


/* =====================================================================
 * ABI v3 — session « scène » (plateau, presets, slicing incrémental)
 *
 * Le contexte garde en mémoire un Model (les objets posés sur le plateau), un
 * PresetBundle (presets vendor), les réglages forcés par l'utilisateur et le
 * Print du dernier slicing (Print::apply n'invalide que ce qui a changé).
 *
 * Conventions :
 *   - les sorties textuelles sont du JSON UTF-8 alloué par la bibliothèque ;
 *     l'appelant les libère avec qsid_free() ;
 *   - toutes les fonctions retournent QSID_OK ou un code QSID_ERR_*, avec un
 *     message dans err_msg (facultatif) ;
 *   - les mutations de la scène sont refusées (QSID_ERR_BUSY) pendant un slicing ;
 *   - unités : mm, degrés ; repère de l'imprimante (origine au coin du plateau).
 * ===================================================================== */

QSID_EXPORT void qsid_free(void *p);

/* ---- Presets (PresetBundle de libslic3r : mêmes héritages et mêmes
 *      conditions de compatibilité que QIDISlicer desktop) ---- */

/* Charge un bundle vendor (resources/profiles/QIDITechnology.ini). */
QSID_EXPORT int qsid_presets_load(qsid_ctx *ctx, const char *vendor_ini,
                                  char *err_msg, size_t err_len);

/* kind : "printer" | "print" | "filament". Liste les presets *compatibles* avec la
 * sélection courante (JSON : ["nom", …]). */
QSID_EXPORT int qsid_presets_list(qsid_ctx *ctx, const char *kind,
                                  char **out_json, char *err_msg, size_t err_len);

/* Sélectionne imprimante, impression et filament (NULL ou "" = garder / premier
 * compatible). out_json = {"printer","print","filament"} effectivement retenus :
 * le moteur remplace un preset devenu incompatible. */
QSID_EXPORT int qsid_presets_select(qsid_ctx *ctx, const char *printer,
                                    const char *print, const char *filament,
                                    char **out_json, char *err_msg, size_t err_len);

/* Remplace la base par un .ini complet (profil exporté du bureau). */
QSID_EXPORT int qsid_config_load_ini(qsid_ctx *ctx, const char *path,
                                     char *err_msg, size_t err_len);

/* ---- Configuration ---- */

/* Config du preset seul / config effective (preset + réglages forcés) :
 * objet JSON {clé: valeur au format .ini}. */
QSID_EXPORT int qsid_config_base(qsid_ctx *ctx, char **out_json);
QSID_EXPORT int qsid_config_effective(qsid_ctx *ctx, char **out_json);
/* Réglages forcés : objet JSON {clé: valeur}. */
QSID_EXPORT int qsid_config_overrides(qsid_ctx *ctx, char **out_json);

/* Force `key` à `value` (validé par la définition de l'option : QSID_ERR_ARG sinon).
 * Une valeur égale à celle du preset retire la surcharge. */
QSID_EXPORT int qsid_config_set(qsid_ctx *ctx, const char *key, const char *value,
                                char *err_msg, size_t err_len);
/* Retire la surcharge de `key` (NULL = toutes). */
QSID_EXPORT int qsid_config_reset(qsid_ctx *ctx, const char *key);

/* Définition de toutes les options FFF (PrintConfigDef) : clé, type, libellé,
 * aide, unité, bornes, énumérations, mode (simple/avancé/expert), défaut. */
QSID_EXPORT int qsid_config_schema(qsid_ctx *ctx, char **out_json);

/* ---- Scène ---- */

QSID_EXPORT int qsid_scene_clear(qsid_ctx *ctx);

/* Ajoute les objets d'un fichier (STL/3MF/OBJ/AMF). Chaque objet est centré sur
 * son origine puis posé sur le plateau (comme Plater::load_files) et placé sans
 * chevaucher les autres. out_json : {"added":[id…],"alerts":{…}}. */
QSID_EXPORT int qsid_scene_add(qsid_ctx *ctx, const char *path,
                               char **out_json, char *err_msg, size_t err_len);

/* État complet : plateau (forme, hauteur max), objets (id, nom, instances avec
 * position/rotation/échelle, boîte englobante monde, hors-plateau), triangles. */
QSID_EXPORT int qsid_scene_info(qsid_ctx *ctx, char **out_json);

/* Maillage d'un objet en coordonnées *locales* (volumes inclus) : 9 floats par
 * triangle. Libérer `*xyz` avec qsid_free(). La transformation d'instance est
 * donnée par qsid_scene_info(). */
QSID_EXPORT int qsid_scene_mesh(qsid_ctx *ctx, uint64_t object_id,
                                float **xyz, size_t *triangle_count,
                                char *err_msg, size_t err_len);

/* Transformation d'une instance. rotation_deg = angles d'Euler (X, Y, Z).
 * drop_to_bed != 0 : pose ensuite l'objet sur le plateau (Z min = 0). */
QSID_EXPORT int qsid_scene_set_transform(qsid_ctx *ctx, uint64_t object_id, int instance,
                                         const double offset[3], const double rotation_deg[3],
                                         const double scale[3], int drop_to_bed);
QSID_EXPORT int qsid_scene_remove(qsid_ctx *ctx, uint64_t object_id);
/* Nombre d'instances (copies) d'un objet ; les nouvelles sont décalées. */
QSID_EXPORT int qsid_scene_set_instances(qsid_ctx *ctx, uint64_t object_id, int count);
QSID_EXPORT int qsid_scene_arrange(qsid_ctx *ctx);
QSID_EXPORT int qsid_scene_drop_to_bed(qsid_ctx *ctx, uint64_t object_id);
/* Pose l'instance sur la face `triangle` (index dans qsid_scene_mesh). */
QSID_EXPORT int qsid_scene_lay_on_face(qsid_ctx *ctx, uint64_t object_id, int instance,
                                       size_t triangle, char *err_msg, size_t err_len);

/* ---- Slicing de la scène ---- */

/* Slice la scène avec la configuration effective. Le Print est conservé : un
 * changement de réglage ne refait que les étapes invalidées.
 * out_summary_json : durées (normal/silencieux, par type), filament (mm, g, cm³),
 * coût, nombre de couches, avertissements. Peut être NULL. */
QSID_EXPORT int qsid_slice_scene(qsid_ctx *ctx, const char *out_gcode,
                                 qsid_progress_cb cb, void *user,
                                 char **out_summary_json,
                                 char *err_msg, size_t err_len);

/* Mouvement du dernier G-code (GCodeProcessorResult). `type` : 0 Noop, 1 Retract,
 * 2 Unretract, 3 Seam, 4 Tool_change, 5 Color_change, 6 Pause, 7 Custom_GCode,
 * 8 Travel, 9 Wipe, 10 Extrude. `role` : 0 None, 1 Perimeter, 2 ExternalPerimeter,
 * 3 OverhangPerimeter, 4 InternalInfill, 5 SolidInfill, 6 TopSolidInfill,
 * 7 Ironing, 8 BridgeInfill, 9 GapFill, 10 Skirt, 11 SupportMaterial,
 * 12 SupportMaterialInterface, 13 WipeTower, 14 Custom. */
typedef struct qsid_move {
    float    x, y, z;        /* position d'arrivée (mm)                         */
    float    feedrate;       /* mm/s                                            */
    float    width, height;  /* mm                                              */
    float    fan_speed;      /* %                                               */
    float    temperature;    /* °C                                              */
    float    time;           /* durée du mouvement (s, mode normal)             */
    float    e_delta;        /* extrusion (mm de filament)                      */
    uint32_t layer;          /* index de couche                                 */
    uint8_t  type;
    uint8_t  role;
    uint8_t  extruder;
    uint8_t  reserved;
} qsid_move;

/* Mouvements du dernier slicing (copie). Libérer avec qsid_free(). */
QSID_EXPORT int qsid_gcode_moves(qsid_ctx *ctx, qsid_move **moves, size_t *count);

/* Vignettes : fournies par l'hôte. Remplit `rgba` (largeur*hauteur*4, lignes de
 * haut en bas) et retourne 1, ou 0 si indisponible. */
typedef int (*qsid_thumbnail_cb)(int width, int height, uint8_t *rgba, void *user);
QSID_EXPORT void qsid_set_thumbnail_provider(qsid_ctx *ctx, qsid_thumbnail_cb cb, void *user);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* QIDISLICE_H */

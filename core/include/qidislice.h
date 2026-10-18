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

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* QIDISLICE_H */

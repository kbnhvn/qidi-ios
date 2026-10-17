/*
 * qidislice.h — ABI C étroite autour du cœur de slicing QIDISlicer (libslic3r)
 * pour l'app iPadOS.
 *
 * Objectif : permettre à Swift (ou à tout autre hôte) de slicer *dans le
 * processus*, sans interface graphique et sans lancer de sous-processus
 * (interdits sous iOS).
 *
 * Contrat de la version 1 :
 *   - le slicing est synchrone et non annulable (voir « Limites » plus bas) ;
 *   - tous les appels sont sérialisés : le cœur libslic3r n'est pas réentrant,
 *     un seul appel à la fois par contexte ;
 *   - les chemins sont en UTF-8.
 *
 * Limites connues de la v1 (à lever en v2 via l'API libslic3r plutôt que la CLI) :
 *   - pas de progression ni d'annulation ;
 *   - la sortie texte du cœur n'est pas capturée (pas de callback de log) ;
 *   - les erreurs fatales du cœur peuvent terminer le processus.
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

/* Code de retour commun aux fonctions de slicing. */
enum {
    QSID_OK                = 0,
    QSID_ERR_ARG           = 1,  /* argument invalide                        */
    QSID_ERR_NO_CONTEXT    = 2,  /* contexte nul / non initialisé             */
    QSID_ERR_IO            = 3,  /* fichier absent ou illisible               */
    QSID_ERR_SLICE_FAILED  = 4   /* le cœur a échoué (voir err_msg)           */
};

/*
 * Crée un contexte.
 *   resources_dir : racine des ressources QIDISlicer (profils QIDITechnology.ini,
 *                   etc.), à l'intérieur du bundle iOS. Peut être NULL.
 *   data_dir      : répertoire inscriptible (conteneur de l'app), utilisé par
 *                   le cœur pour ses caches/config. Peut être NULL.
 * Retourne NULL si l'initialisation du cœur échoue.
 * Le cœur ne doit être initialisé qu'une fois par processus.
 */
QSID_EXPORT qsid_ctx *qsid_create(const char *resources_dir, const char *data_dir);

/* Libère le contexte. À n'appeler qu'en fin de vie de l'app. */
QSID_EXPORT void qsid_destroy(qsid_ctx *ctx);

/* Version du cœur, ex. "QIDISlicer 1.2.5 (libslic3r)". */
QSID_EXPORT int qsid_version(char *buf, size_t buflen);

/*
 * Slice `model_path` (STL, 3MF, OBJ, AMF, STEP si compilé) vers `out_gcode`.
 *   config_path : fichier .ini de configuration (format PrusaSlicer/QIDISlicer).
 *                 Peut être NULL ou vide : les valeurs par défaut du cœur sont
 *                 alors utilisées, ce qui n'est PAS un profil d'imprimante
 *                 utilisable — passer un profil.
 *   out_gcode   : chemin du G-code à produire (écrasé s'il existe).
 *   err_msg/err_len : tampon recevant un message d'erreur (peut être NULL).
 */
QSID_EXPORT int qsid_slice(qsid_ctx *ctx,
                           const char *model_path,
                           const char *config_path,
                           const char *out_gcode,
                           char *err_msg, size_t err_len);

/*
 * Échappatoire : construit et exécute une ligne de commande du cœur,
 * exactement comme l'exécutable `qidi-slicer`. `argv` ne doit PAS contenir le
 * nom du programme (il est ajouté). Utile pour `--query-printer-models`,
 * `--export-3mf`, etc. depuis l'app.
 */
QSID_EXPORT int qsid_run_cli(qsid_ctx *ctx,
                             int argc, const char *const *argv,
                             char *err_msg, size_t err_len);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* QIDISLICE_H */

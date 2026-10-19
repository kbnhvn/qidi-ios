/*
 * ctx.hpp — état interne du contexte (partagé entre qidislice.cpp et scene.cpp).
 */
#ifndef QSID_CTX_HPP
#define QSID_CTX_HPP

#include "qidislice.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "libslic3r/libslic3r.h"
#include "libslic3r/Model.hpp"
#include "libslic3r/Print.hpp"
#include "libslic3r/PrintConfig.hpp"
#include "libslic3r/PresetBundle.hpp"
#include "libslic3r/GCode/GCodeProcessor.hpp"

namespace qsid {

inline std::string tail(const std::string &msg, size_t max = 480)
{
    return msg.size() <= max ? msg : "…" + msg.substr(msg.size() - max);
}

inline void set_err(char *err_msg, size_t err_len, const std::string &msg)
{
    if (!err_msg || err_len == 0)
        return;
    std::snprintf(err_msg, err_len, "%s", tail(msg).c_str());
}

/* Copie une chaîne dans un tampon alloué par malloc (libéré par qsid_free). */
inline char *dup_string(const std::string &s)
{
    char *p = static_cast<char *>(std::malloc(s.size() + 1));
    if (p)
        std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}

} // namespace qsid

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

    /* ---- v3 : session « scène » ---- */
    Slic3r::Model                            model;
    std::unique_ptr<Slic3r::PresetBundle>    presets;
    /* Base de configuration : config complète du preset sélectionné (ou d'un .ini
     * importé). Les surcharges de l'utilisateur sont appliquées par-dessus. */
    Slic3r::DynamicPrintConfig               base_config;
    bool                                     base_from_ini = false;
    std::map<std::string, std::string>       overrides;
    /* Print du dernier slicing : Print::apply n'invalide que ce qui change. */
    std::unique_ptr<Slic3r::Print>           print;
    Slic3r::GCodeProcessorResult             last_result;
    bool                                     has_result = false;
    qsid_thumbnail_cb                        thumbnail_cb = nullptr;
    void                                    *thumbnail_user = nullptr;
};

#endif /* QSID_CTX_HPP */

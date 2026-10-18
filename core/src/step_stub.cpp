/*
 * step_stub.cpp — import STEP désactivé (OCCT absent de la v1).
 *
 * Sur Apple, Format/STEP.cpp ne charge pas le wrapper dynamiquement : il prend
 * directement l'adresse de `load_step_internal` (liaison statique, comme dans le
 * binaire macOS où OCCT est lié statiquement). Avec SLIC3R_ENABLE_FORMAT_STEP=OFF,
 * le wrapper n'est pas construit et le symbole manquerait à l'édition de liens.
 *
 * On fournit donc l'implémentation : l'import STEP échoue proprement, avec un
 * message explicite, au lieu d'empêcher l'app de se lier.
 */
#include "occt_wrapper/OCCTWrapper.hpp"

#include <optional>
#include <utility>

namespace Slic3r {

extern "C" bool load_step_internal(const char * /*path*/,
                                   OCCTResult *result,
                                   std::optional<std::pair<double, double>> /*deflections*/)
{
    if (result)
        result->error_str = "STEP import is not available: this build was compiled "
                            "without OCCT support (SLIC3R_ENABLE_FORMAT_STEP=OFF).";
    return false;
}

} // namespace Slic3r

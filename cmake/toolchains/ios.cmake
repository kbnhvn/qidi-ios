# Toolchain iOS pour le cœur de slicing QIDISlicer.
#
#   cmake -S third_party/qidislicer -B build/ios \
#         -DCMAKE_TOOLCHAIN_FILE=$PWD/cmake/toolchains/ios.cmake \
#         -DSLIC3R_GUI=OFF -DSLIC3R_IOS_CORE=ON ...
#
# Variables d'entrée :
#   QSID_SDK        iphoneos (défaut) | iphonesimulator
#   QSID_ARCH       arm64 (défaut)
#   QSID_IOS_MIN    cible de déploiement minimale (défaut 15.0)
#   QSID_HOST_CC / QSID_HOST_CXX
#                   compilateurs *de la machine de build*, utilisés par les recettes
#                   autotools (GMP, MPFR) qui ont besoin de compiler et d'*exécuter* des
#                   programmes générateurs. Voir scripts/host-cc.sh.

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_VERSION 1)

if(NOT QSID_SDK)
    set(QSID_SDK iphoneos)
endif()
if(NOT QSID_ARCH)
    set(QSID_ARCH arm64)
endif()
if(NOT QSID_IOS_MIN)
    set(QSID_IOS_MIN 15.0)
endif()

set(CMAKE_OSX_SYSROOT "${QSID_SDK}" CACHE STRING "" FORCE)
set(CMAKE_OSX_ARCHITECTURES "${QSID_ARCH}" CACHE STRING "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET "${QSID_IOS_MIN}" CACHE STRING "" FORCE)

# CMAKE_SYSTEM_PROCESSOR n'est pas renseignée pour iOS (CMake ne déduit rien de
# l'hôte en cross-compilation, et c'est la variable *cible*). Or plusieurs
# dépendances l'utilisent telle quelle :
#   - libjpeg-turbo 3.0.1 : string(TOLOWER ${CMAKE_SYSTEM_PROCESSOR} ...) →
#     « string no output variable specified » (constaté sur runner) ;
#   - OpenVDB : if (${CMAKE_SYSTEM_PROCESSOR} MATCHES "arm" ...) → « if » invalide ;
#   - GMP/OpenSSL : choix de la cible/du triplet.
# C'est la cause racine la plus citée par les portages comparables. On l'annonce
# donc explicitement — c'est aussi la vérité : la cible est arm64.
set(CMAKE_SYSTEM_PROCESSOR "${QSID_ARCH}" CACHE STRING "" FORCE)

# On ne veut pas de .app pour les bibliothèques/exécutables intermédiaires.
set(CMAKE_MACOSX_BUNDLE OFF)

# CMake a besoin de savoir qu'il ne doit pas essayer de lier et d'exécuter les
# projets de test (try_compile → try_run) : sur iOS, on n'exécute rien.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# Le préfixe des dépendances (Boost, CGAL, GMP…) et le sysroot doivent tous deux
# être dans le root path, sinon find_package ne voit que le SDK.
if(DEFINED QSID_DEPS_PREFIX AND NOT QSID_DEPS_PREFIX STREQUAL "")
    list(APPEND CMAKE_FIND_ROOT_PATH "${QSID_DEPS_PREFIX}")
    set(CMAKE_PREFIX_PATH "${QSID_DEPS_PREFIX}" CACHE PATH "" FORCE)
endif()

# Sysroot résolu (device ou simulateur) : on l'ajoute au root path pour que les
# recherches de bibliothèques (.tbd) et de frameworks restent bornées au SDK.
execute_process(
    COMMAND xcrun --sdk "${QSID_SDK}" --show-sdk-path
    OUTPUT_VARIABLE _qsid_sysroot
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
if(_qsid_sysroot AND NOT _qsid_sysroot STREQUAL "")
    list(APPEND CMAKE_FIND_ROOT_PATH "${_qsid_sysroot}")
endif()

# Les dépendances ne doivent pas être piochées dans l'hôte (Homebrew, /usr/local) :
# c'est la fuite silencieuse qui fait diverger un build iOS d'un build desktop.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Compilateurs hôtes (voir scripts/host-cc.sh) : les recettes GMP/MPFR les passent
# en CC_FOR_BUILD. Un simple /usr/bin/clang ne suffit pas : un build iOS exporte
# SDKROOT, clang l'honore, et le compilateur « hôte » émet alors du code iOS.
if(NOT QSID_HOST_CC)
    set(QSID_HOST_CC "" CACHE FILEPATH "Compilateur C de la machine de build (wrapper)")
endif()
if(NOT QSID_HOST_CXX)
    set(QSID_HOST_CXX "" CACHE FILEPATH "Compilateur C++ de la machine de build (wrapper)")
endif()

# Le projet amont décide s'il est en cross-compilation en comparant
# CMAKE_SYSTEM_PROCESSOR à CMAKE_OSX_ARCHITECTURES. Sur iOS la première variable
# n'est pas renseignée de façon fiable (vide, ou égale à l'hôte), donc on annonce
# la plateforme explicitement : le patch 0001 lit QSID_IS_IOS pour forcer le mode
# cross (donc : pas de tests unitaires, pas d'exécution de binaires).
set(QSID_IS_IOS TRUE)

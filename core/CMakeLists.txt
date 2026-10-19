# Cible « ios-core » : ABI C + gate de vérification.
#
# Ce fichier est copié dans l'arbre amont par scripts/bootstrap.sh
# (third_party/qidislicer/ios-core/) et ajouté par le patch 0007 depuis
# src/CMakeLists.txt, donc :
#   - les variables SLIC3R_CLI_SOURCES, SLIC3R_GUI… sont dans la portée ;
#   - les cibles amont (libslic3r, libcereal, slic3r-arrange-wrapper,
#     libseqarrange, stb_image) sont déjà définies.

set(QSID_CORE_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/src/qidislice.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/scene.cpp)

# Sans OCCT (SLIC3R_ENABLE_FORMAT_STEP=OFF), Format/STEP.cpp référence malgré tout
# load_step_internal() sur Apple (liaison statique du wrapper) : on fournit un stub
# qui fait échouer l'import STEP proprement. Voir core/src/step_stub.cpp.
if (NOT SLIC3R_ENABLE_FORMAT_STEP)
    list(APPEND QSID_CORE_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/src/step_stub.cpp)
endif()

# SLIC3R_CLI_SOURCES est défini par src/CMakeLists.txt avec des chemins *relatifs à
# src/* (ex. CLI/PrintHelp.cpp). Depuis ios-core/, il faut les préfixer, sinon CMake
# les cherche ici et échoue (« Cannot find source file: QIDISlicer.hpp »).
set(_qsid_cli_sources "")
foreach(_src IN LISTS SLIC3R_CLI_SOURCES)
    list(APPEND _qsid_cli_sources "${CMAKE_CURRENT_SOURCE_DIR}/../src/${_src}")
endforeach()

# Bibliothèque statique : c'est elle que l'app iPadOS lie.
add_library(qidislice STATIC ${QSID_CORE_SOURCES} ${_qsid_cli_sources})

target_include_directories(qidislice PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
# Les sources CLI/QIDISlicer.hpp s'incluent relativement à src/.
target_include_directories(qidislice PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../src)

target_link_libraries(qidislice
    PRIVATE
        libslic3r
        libcereal
        slic3r-arrange-wrapper
        libseqarrange
        stb_image
)

if(APPLE)
    # Mêmes dépendances système que la cible QIDISlicer amont, plus Foundation :
    # libslic3r/MacUtils.mm utilise NSFileManager (classe Objective-C). L'app iOS
    # lie Foundation de son côté ; le binaire de gate (CLI) en a besoin ici.
    target_link_libraries(qidislice PRIVATE
        "-liconv"
        "-framework IOKit"
        "-framework CoreFoundation"
        "-framework Foundation"
        "-lc++")
endif()

# Banc de test : ASan/UBSan sur *notre* code seulement (l'amont reste non instrumenté).
option(QSID_CORE_SANITIZE "Compile ios-core avec ASan+UBSan (tests Linux/macOS hôte)" OFF)
if(QSID_CORE_SANITIZE)
    target_compile_options(qidislice PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer -g)
    target_link_options(qidislice PUBLIC -fsanitize=address,undefined)
endif()

set_target_properties(qidislice PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    CXX_VISIBILITY_PRESET hidden
)

# Gate : binaire de vérification, uniquement pour l'hôte (macOS/Linux). Sur iOS
# les exécutables sont des bundles et le vrai test est la compilation de l'app.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    add_executable(qidislice_gate ${CMAKE_CURRENT_SOURCE_DIR}/gate/main.cpp)
    target_link_libraries(qidislice_gate PRIVATE qidislice)

    add_executable(qidislice_scene_gate ${CMAKE_CURRENT_SOURCE_DIR}/gate/scene_gate.cpp)
    target_link_libraries(qidislice_scene_gate PRIVATE qidislice)
endif()

# Cible « ios-core » : ABI C + gate de vérification.
#
# Ce fichier est copié dans l'arbre amont par scripts/bootstrap.sh
# (third_party/qidislicer/ios-core/) et ajouté par le patch 0007 depuis
# src/CMakeLists.txt, donc :
#   - les variables SLIC3R_CLI_SOURCES, SLIC3R_GUI… sont dans la portée ;
#   - les cibles amont (libslic3r, libcereal, slic3r-arrange-wrapper,
#     libseqarrange, stb_image) sont déjà définies.

set(QSID_CORE_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/src/qidislice.cpp)

# Bibliothèque statique : c'est elle que l'app iPadOS lie.
add_library(qidislice STATIC ${QSID_CORE_SOURCES} ${SLIC3R_CLI_SOURCES})

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
    # Mêmes dépendances système que la cible QIDISlicer amont.
    target_link_libraries(qidislice PRIVATE "-liconv" "-framework IOKit" "-framework CoreFoundation" "-lc++")
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
endif()

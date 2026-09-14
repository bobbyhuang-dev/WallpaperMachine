// Deep test for .mdl version stamp MDLV0014.
//
// Pins workshops that ship at least one MDLV 14 puppet so any change in
// WPMdlParser bone-tree or animation track parsing surfaces here.
//
// To regenerate after a deliberate parser change:
//     ninja -C build wpdump
//     ./build/tests/wpdump workshop/<id> \
//         tests/fixtures/mdlv_14/<id>.json

#include "fixture_helpers.hpp"

DEFINE_FIXTURE_TEST_SUITE(
    Mdlv14Test,
    { "2835012244", WAYWALLEN_FIXTURE_DIR "/mdlv_14/2835012244.json" });

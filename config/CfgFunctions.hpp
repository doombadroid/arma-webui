// SPDX-License-Identifier: MIT
/*
    arma-webui -- CfgFunctions fragment.

    #include this inside your mission's CfgFunctions, at the TOP LEVEL -- as a
    sibling of your own tag classes, not inside one:

        class CfgFunctions {
            class MyTag { tag = "my"; class stuff { file = "..."; }; };
            #include "webui\config\CfgFunctions.hpp"      // <- here
        };

    Nested inside another tag, "webui" becomes a category and core/diagnostics
    become functions whose `file` is a directory. The engine then spams
    "Script webui\functions not found" and no webui_fnc_* exists. Missions whose
    CfgFunctions body lives in an included file make this easy to get wrong,
    because the enclosing class is in a different file.

    Adjust `file =` if the library is not at <mission>\webui\.
*/
class webui {
    class core {
        file = "webui\functions";
        class init {};          // wire a CT_WEBBROWSER control up as a channel
        class on {};            // register a handler a page may call
        class push {};          // SQF -> page value push
        class call {};          // SQF -> page call WITH a return value
        class exec {};          // ExecJS, queued until the page is up
        class freeze {};        // StopBrowser / ResumeBrowser
        class prompt {};        // native text entry overlay
        class volumeSlave {};   // make page audio obey the game's volume sliders
        class clampCheck {};    // once per session: is frame delivery clamped? (FINDINGS 1)
    };
    class diagnostics {
        file = "webui\diagnostics";
        class awaitPage {};     // wait for a page, hand back its control
        class countDraws {};    // count "Draw" events over a window
        class drawRate {};      // how often does the engine actually paint?
        class bench {};         // A/B/A frame cost + real viewport vs control size
        class forceProbe {};    // every engine-side lever for forcing repaints
        class paintProbe {};    // GIF / overlay: who is throttling the paint?
        class focusProbe {};    // does window focus feed the frame clamp?
        class latencyProbe {};  // per-leg bridge latency, both clocks, payload ladder
        class msgCapProbe {};   // bisect the page->SQF message truncation cap
    };
};

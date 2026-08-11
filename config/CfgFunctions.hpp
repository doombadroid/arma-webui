// SPDX-License-Identifier: MIT
/*
    arma-webui -- CfgFunctions fragment.

    #include this inside your mission's CfgFunctions. The tag "webui" gives you
    webui_fnc_init, webui_fnc_push and so on. Adjust `file =` if you put the
    library somewhere other than <mission>\webui\.
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
    };
};

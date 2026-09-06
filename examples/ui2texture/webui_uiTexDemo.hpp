/*
    webui_uiTexDemo.hpp -- a display that is never opened on screen.

    It exists to be NAMED in a UI-on-texture procedural string:

        #(rgb,1024,1024,1)uiEx(display:webui_uiTexDemo,uniqueName:demo_x,bgColor:#000000ff)

    The engine instantiates the display off-screen and renders it into that texture, and
    fn_uiTexDemo.sqf paints the texture onto a vehicle's hidden selections. One CT_WEBBROWSER
    fills the display, at matrix.html. Include this from description.ext (or a mod config)
    and put matrix.html somewhere allowedHTMLLoadURIs covers.

    THE DISPLAY IS 0..1, NOT SAFEZONE. A dialog is composited over the player's screen, so
    it spans safezoneX/Y/W/H; this one is rendered into a square texture whose viewport is
    the display's own 0..1 space (uiEx viewportX/Y/W/H default 0,0,1,1). Safezone maths on
    a texture pushes the page part-way off it.

    NO BRIDGE. matrix.html runs itself and never calls back, so nothing attaches
    webui_fnc_init. If your page needs the four directions, attach it exactly as for a
    dialog once the display exists -- the control is an ordinary CT_WEBBROWSER.
*/
class webui_uiTexDemo {
    idd = 941900;   // any unused idd
    name = "webui_uiTexDemo";
    movingEnable = false;
    enableSimulation = true;
    class controls {
        class Page {
            idc = 941901;
            type = 106;   // CT_WEBBROWSER
            style = 0;
            x = 0; y = 0; w = 1; h = 1;
            colorBackground[] = {0,0,0,1};
            colorText[] = {1,1,1,1};
            font = "RobotoCondensed";
            sizeEx = 0.03;
            url = "matrix.html";   // path relative to the mission root, under allowedHTMLLoadURIs
        };
    };
};

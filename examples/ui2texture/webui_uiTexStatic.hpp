/*
    uitex_static.hpp -- webui_uiTexStatic (941920): never opened on screen; named in a UI-on-texture
    string by webui_fnc_reskinBurst, which paints static.html onto a car for two seconds
    between skins. Same shape as webui_uiTexDemo.hpp: 0..1 coords, one CT_WEBBROWSER.
*/
class webui_uiTexStatic {
    idd = 941920;
    name = "webui_uiTexStatic";
    movingEnable = false;
    enableSimulation = true;
    class controls {
        class Page {
            idc = 941921;
            type = 106;
            style = 0;
            x = 0; y = 0; w = 1; h = 1;
            colorBackground[] = {0,0,0,1};
            colorText[] = {1,1,1,1};
            font = "RobotoCondensed";
            sizeEx = 0.03;
            url = "static.html";
        };
    };
};

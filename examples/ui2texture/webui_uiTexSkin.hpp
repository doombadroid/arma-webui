/*
    uitex_skin.hpp -- webui_uiTexSkin (941930): the display a server-streamed HTML skin renders in.
    Named in the texture string fn_htmlSkin broadcasts; one instance per SKIN id, shared by every
    car wearing it. The browser starts on skin.html (black + webui boot) and the server
    replaces the document with skins\<id>.html through webui_fnc_serve.
*/
class webui_uiTexSkin {
    idd = 941930;
    name = "webui_uiTexSkin";
    movingEnable = false;
    enableSimulation = true;
    class controls {
        class Page {
            idc = 941931;
            type = 106;
            style = 0;
            x = 0; y = 0; w = 1; h = 1;
            colorBackground[] = {0,0,0,1};
            colorText[] = {1,1,1,1};
            font = "RobotoCondensed";
            sizeEx = 0.03;
            url = "skin.html";
        };
    };
};

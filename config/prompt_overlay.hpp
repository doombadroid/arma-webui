// SPDX-License-Identifier: MIT
/*
    arma-webui -- native text entry overlay.

    Typed text DOES reach the DOM (see docs/FINDINGS.md), so a real <input> in
    a page works. This exists for a native-looking prompt, and for the case
    where the browser is frozen.

    These controls start hidden. webui_fnc_prompt shows them, waits for
    OK/Cancel, and returns the string to the calling page.

    USAGE -- include INSIDE a dialog's `class controls`, AFTER the browser
    control so it draws on top (native controls do render over the browser):

        class controls {
            class Page { ... type = 106; ... };
            #include "webui\config\prompt_overlay.hpp"
        };

    Reserves idc 937410-937415. Everything is declared inline rather than
    inherited, so the library does not depend on any base classes existing in
    the host mission. Positions are in plain UI coordinates; edit freely.
*/

class WebUI_PromptDim {
    idc = 937410; show = 0;
    type = 0; style = 0;                       // CT_STATIC
    x = 0; y = 0; w = 1; h = 1;
    font = "RobotoCondensed"; sizeEx = 0.03;
    colorText[]       = {0,0,0,0};
    colorBackground[] = {0,0,0,0.72};
    text = "";
};
class WebUI_PromptPanel {
    idc = 937411; show = 0;
    type = 0; style = 0;
    x = 0.30; y = 0.42; w = 0.40; h = 0.17;
    font = "RobotoCondensed"; sizeEx = 0.03;
    colorText[]       = {0,0,0,0};
    colorBackground[] = {0.047,0.09,0.07,1};
    text = "";
};
class WebUI_PromptTitle {
    idc = 937412; show = 0;
    type = 13; style = 0;                      // CT_STRUCTURED_TEXT
    x = 0.315; y = 0.435; w = 0.37; h = 0.035;
    size = 0.032; font = "RobotoCondensed";
    colorText[]       = {0.86,0.905,0.878,1};
    colorBackground[] = {0,0,0,0};
    text = "";
    class Attributes { align = "left"; color = "#dcefe0"; };
};
class WebUI_PromptEdit {
    idc = 937413; show = 0;
    type = 2; style = 0;                       // CT_EDIT
    x = 0.315; y = 0.478; w = 0.37; h = 0.038;
    font = "RobotoCondensed"; sizeEx = 0.032;
    colorText[]       = {0.86,0.905,0.878,1};
    colorBackground[] = {0.02,0.045,0.035,1};
    colorSelection[]  = {0.788,0.886,0.10,0.5};
    colorDisabled[]   = {0.4,0.4,0.4,1};
    autocomplete = "";
    canModify = 1;
    maxChars = 256;
    text = "";
};
class WebUI_PromptOk {
    idc = 937414; show = 0;
    type = 1; style = 2;                       // CT_BUTTON, ST_CENTER
    x = 0.555; y = 0.532; w = 0.13; h = 0.040;
    font = "RobotoCondensed"; sizeEx = 0.030;
    text = "OK";
    colorText[]           = {0.03,0.06,0.05,1};
    colorBackground[]     = {0.788,0.886,0.10,1};
    colorFocused[]        = {0.85,0.95,0.15,1};
    colorBackgroundDisabled[] = {0.3,0.3,0.3,1};
    colorDisabled[]       = {0.5,0.5,0.5,1};
    colorShadow[]         = {0,0,0,0};
    colorBorder[]         = {0,0,0,0};
    borderSize = 0; offsetX = 0; offsetY = 0; offsetPressedX = 0; offsetPressedY = 0;
    soundEnter[]  = {"",0,1}; soundPush[]   = {"",0,1};
    soundClick[]  = {"",0,1}; soundEscape[] = {"",0,1};
    onButtonClick = "with uiNamespace do { WEBUI_promptResult = ctrlText ((ctrlParent (uiNamespace getVariable ['WEBUI_ctrl', controlNull])) displayCtrl 937413); WEBUI_promptDone = 1; };";
};
class WebUI_PromptCancel : WebUI_PromptOk {
    idc = 937415; show = 0;
    x = 0.315; y = 0.532; w = 0.13; h = 0.040;
    text = "CANCEL";
    colorText[]       = {0.78,0.32,0.32,1};
    colorBackground[] = {0.02,0.045,0.035,1};
    colorFocused[]    = {0.05,0.09,0.07,1};
    onButtonClick = "with uiNamespace do { WEBUI_promptResult = nil; WEBUI_promptDone = 1; };";
};

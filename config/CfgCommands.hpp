// SPDX-License-Identifier: MIT
/*
    arma-webui -- description.ext fragment.

    WITHOUT THIS NOTHING WORKS, AND IT FAILS SILENTLY. A page served from a path
    that is not whitelisted gets no A3API binding at all: it renders perfectly
    and can never call back. `+=` extends the engine defaults rather than
    replacing them.

    Put your pages under <mission>\ui\html\ or change the pattern to match.
*/
class CfgCommands
{
    allowedHTMLLoadURIs[] += {
        "ui\\html\\*"
    };
};

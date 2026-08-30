// SPDX-License-Identifier: MIT
/*
    arma-webui -- description.ext fragment.

    WITHOUT THIS NOTHING WORKS, AND IT FAILS SILENTLY. A page served from a path
    that is not whitelisted gets no A3API binding at all: it renders perfectly
    and can never call back. `+=` extends the engine defaults rather than
    replacing them.

    Put your pages under <mission>\ui\html\ or change the pattern to match.

    THE DOUBLED BACKSLASHES BELOW ARE CORRECT. DO NOT "FIX" THEM.

    Reading Arma config syntax alone suggests they are wrong -- config strings
    have no backslash-escape processing, so "ui\\html\\*" looks like it should
    register a literal two-backslash pattern that could never match
    ui\html\mypage.html. Two separate reviews have raised exactly that, both
    times as a critical "nothing can ever work" finding.

    It is contradicted by the authoritative record: a production mission ships
    this identical doubled form -- allowedHTMLLoadURIs[] += {"ui\\html\\*",
    "ui\\html\\casino\\*", "webui\\ui\\*"} -- and its pages demonstrably
    load and bind A3API. Every measured number in docs/FINDINGS.md was taken
    through a whitelist written this way; if the pattern never matched, none of
    those measurements could exist.

    A deduction that something has never worked loses to an instance of it
    working. If you change this, you are betting the entire library's silent
    failure mode on a language-rule argument over observed behaviour.
*/
class CfgCommands
{
    allowedHTMLLoadURIs[] += {
        "ui\\html\\*"
    };
};

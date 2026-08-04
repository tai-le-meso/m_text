import Foundation

/// A small set of snippets available with nothing installed, so tab triggers work out of
/// the box (T91).
///
/// Deliberately modest. This is not an attempt to ship Sublime's whole snippet library —
/// it is enough to make the feature discoverable and to exercise every part of the syntax
/// (placeholders, mirrors, `$0`, `$SELECTION`). Anything in the user's Packages/Snippets
/// folder is loaded alongside these and wins ties, so nothing here blocks a replacement.
public enum BuiltInSnippets {

    public static let all: [Snippet] = [
        // Language-scoped: `for` means something different in each, and scope specificity
        // is what lets them share one trigger.
        Snippet(content: "for ${1:item} in ${2:sequence}:\n\t$0",
                tabTrigger: "for", scope: "source.python",
                description: "for loop (Python)", name: "for-python"),
        Snippet(content: "for ${1:item} in ${2:sequence} {\n\t$0\n}",
                tabTrigger: "for", scope: "source.swift",
                description: "for-in loop (Swift)", name: "for-swift"),
        Snippet(content: "for (int ${1:i} = 0; $1 < ${2:count}; $1++) {\n\t$0\n}",
                tabTrigger: "for", scope: "source.c, source.c++, source.java, source.cs",
                description: "for loop (C-family) — mirrors the counter", name: "for-c"),

        // Generic, unscoped: available everywhere as a fallback.
        Snippet(content: "if ${1:condition} {\n\t$0\n}",
                tabTrigger: "if", scope: nil,
                description: "if block", name: "if"),
        Snippet(content: "func ${1:name}(${2:parameters}) -> ${3:Void} {\n\t$0\n}",
                tabTrigger: "func", scope: "source.swift",
                description: "function (Swift)", name: "func-swift"),
        Snippet(content: "def ${1:name}(${2:args}):\n\t${0:pass}",
                tabTrigger: "def", scope: "source.python",
                description: "function (Python)", name: "def-python"),

        // `$SELECTION` with a fallback — the canonical "wrap what I selected" snippet, and
        // the reason `${VAR:default}` exists.
        Snippet(content: "<${1:div}>${SELECTION:$0}</$1>",
                tabTrigger: "tag", scope: "text.html",
                description: "wrap selection in a tag — mirrors the tag name", name: "tag"),
        Snippet(content: "\"\"\"\n${SELECTION:$0}\n\"\"\"",
                tabTrigger: "doc", scope: "source.python",
                description: "docstring around the selection", name: "docstring"),
    ]
}

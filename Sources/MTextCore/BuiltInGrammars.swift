import Foundation

/// Grammars compiled into the binary so common files colour with no setup.
///
/// Written as real `.sublime-syntax` source and loaded through the same path as
/// user-supplied grammars, so a bug in the YAML parser or the tokenizer shows up here
/// rather than only in the field.
///
/// Every literal uses Swift **raw** strings (`#"""` … `"""#`). That means a regex is
/// written exactly as it appears in a real syntax file — `\b`, not `\\b` — and an
/// embedded `"""` needs no escaping. Doubling backslashes by hand is how these got
/// broken the first time.
///
/// To add a language: drop a `.sublime-syntax` file in
/// `~/Library/Application Support/m_text/Packages`, or use Syntax ▸ Import Syntax…
public enum BuiltInGrammars {

    public static func registry() -> GrammarRegistry {
        let registry = GrammarRegistry()
        registry.reload(packagesDirectory: nil)
        return registry
    }

    /// Detection is first-match-wins, so more specific grammars come first: `.properties`
    /// before YAML (both are key/value), TypeScript before JavaScript. Only C actually
    /// lists the bare `.h` extension (C++ headers use `.hpp`/`.hh`/`.h++`; Objective-C
    /// uses `.m`/`.mm`, no `.h` at all), so a plain C header is always what `.h` resolves
    /// to here; picking C++ or Objective-C for a given header is a manual Syntax-menu
    /// choice. Objective-C is registered before MATLAB for the same reason: both claim
    /// bare `.m`, and Objective-C is the far more common case for this codebase.
    public static var all: [String] {
        [
            json, yaml, properties, xml,
            java, swift, python, shell,
            typescript, javascript, css, markdown,
            sql, perl, php, ruby,
            c, cpp, csharp, objectivec,
            rust, go,
            lua, makefile, diff, toml,
            r, haskell, scala, clojure,
            asp, actionscript, applescript, batchfile,
            d, erlang, dot, groovy,
            latex, lisp, matlab, ocaml,
            pascal, erb, regexp, restructuredtext,
            tcl, textile,
        ]
    }

    // MARK: - JSON

    public static let json = #"""
    %YAML 1.2
    ---
    name: JSON
    scope: source.json
    file_extensions: [json, jsonc, sublime-settings, sublime-keymap, sublime-project, sublime-color-scheme, webmanifest]
    contexts:
      main:
        - match: '"'
          scope: punctuation.definition.string.begin.json
          push: double_quoted_string
        - match: '\b(?:true|false)\b'
          scope: constant.language.json
        - match: '\bnull\b'
          scope: constant.language.null.json
        - match: '-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][-+]?\d+)?'
          scope: constant.numeric.json
        - match: '//'
          scope: punctuation.definition.comment.json
          push: line_comment
        - match: '/\*'
          scope: punctuation.definition.comment.json
          push: block_comment
        - match: '[{}\[\]]'
          scope: punctuation.section.json
        - match: '[:,]'
          scope: punctuation.separator.json
      double_quoted_string:
        - meta_scope: string.quoted.double.json
        - match: '\\(?:["\\/bfnrt]|u\h{4})'
          scope: constant.character.escape.json
        - match: '\\.'
          scope: invalid.illegal.unrecognized-escape.json
        - match: '"'
          scope: punctuation.definition.string.end.json
          pop: true
      line_comment:
        - meta_scope: comment.line.double-slash.json
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.json
        - match: '\*/'
          pop: true
    """#

    // MARK: - YAML

    public static let yaml = #"""
    %YAML 1.2
    ---
    name: YAML
    scope: source.yaml
    file_extensions: [yaml, yml, sublime-syntax, clang-format, gemrc]
    first_line_match: '^%YAML\b'
    contexts:
      main:
        - match: '^\s*#'
          scope: punctuation.definition.comment.yaml
          push: comment
        - match: '\s#(?=\s)'
          scope: punctuation.definition.comment.yaml
          push: comment
        - match: '^(---|\.\.\.)\s*$'
          scope: entity.other.document-marker.yaml
        - match: '^\s*(-)(?=\s|$)'
          captures:
            1: punctuation.definition.list_item.yaml
        - match: '(&|\*)[A-Za-z0-9_-]+'
          scope: variable.other.anchor.yaml
        - match: '!!?[A-Za-z0-9_/-]*'
          scope: storage.type.tag.yaml
        - match: '^\s*([A-Za-z0-9_][\w.-]*)\s*(:)(?=\s|$)'
          captures:
            1: entity.name.tag.yaml
            2: punctuation.separator.key-value.yaml
        - match: '("[^"]*")\s*(:)(?=\s|$)'
          captures:
            1: entity.name.tag.yaml
            2: punctuation.separator.key-value.yaml
        - match: '"'
          scope: punctuation.definition.string.begin.yaml
          push: double_quoted_string
        - match: "'"
          scope: punctuation.definition.string.begin.yaml
          push: single_quoted_string
        - match: '[|>][-+]?\s*$'
          scope: keyword.control.flow.block-scalar.yaml
        - match: '\b(?:true|false|yes|no|on|off|null)\b'
          scope: constant.language.yaml
        # `~` needs its own pattern: \b cannot hold on both sides of a non-word character.
        - match: '(?<![\w~])~(?![\w~])'
          scope: constant.language.null.yaml
        - match: '\$\{[^}]*\}'
          scope: variable.other.placeholder.yaml
        - match: '\b-?\d+(?:\.\d+)?\b'
          scope: constant.numeric.yaml
        - match: '[\[\]{},]'
          scope: punctuation.section.yaml
      comment:
        - meta_scope: comment.line.number-sign.yaml
        - match: '$'
          pop: true
      double_quoted_string:
        - meta_scope: string.quoted.double.yaml
        - match: '\\.'
          scope: constant.character.escape.yaml
        - match: '"'
          scope: punctuation.definition.string.end.yaml
          pop: true
      single_quoted_string:
        - meta_scope: string.quoted.single.yaml
        - match: "''"
          scope: constant.character.escape.yaml
        - match: "'"
          scope: punctuation.definition.string.end.yaml
          pop: true
    """#

    // MARK: - Java / Spring properties

    public static let properties = #"""
    %YAML 1.2
    ---
    name: Java Properties
    scope: source.java-properties
    file_extensions: [properties, ini, cfg, conf, editorconfig, gitconfig]
    contexts:
      main:
        - match: '^\s*[#!]'
          scope: punctuation.definition.comment.java-properties
          push: comment
        - match: '^\s*(\[)([^\]]*)(\])'
          captures:
            1: punctuation.definition.section.begin.java-properties
            2: entity.name.section.java-properties
            3: punctuation.definition.section.end.java-properties
        - match: '^\s*([^=:\s#!][^=:]*?)\s*([=:])'
          captures:
            1: entity.name.tag.java-properties
            2: punctuation.separator.key-value.java-properties
          push: value
      comment:
        - meta_scope: comment.line.java-properties
        - match: '$'
          pop: true
      value:
        - meta_scope: string.unquoted.java-properties
        - match: '\$\{[^}]*\}'
          scope: variable.other.placeholder.java-properties
        - match: '\\$'
          scope: punctuation.separator.continuation.java-properties
        - match: '\\.'
          scope: constant.character.escape.java-properties
        - match: '$'
          pop: true
    """#

    // MARK: - XML / HTML

    public static let xml = #"""
    %YAML 1.2
    ---
    name: XML
    scope: text.xml
    file_extensions: [xml, plist, xib, storyboard, svg, xsd, xsl, xslt, pom, html, htm, vue, tmlanguage, tmtheme, tmpreferences]
    first_line_match: '^<\?xml\b'
    contexts:
      main:
        - match: '<!--'
          scope: punctuation.definition.comment.xml
          push: comment
        - match: '<!\[CDATA\['
          scope: punctuation.definition.string.begin.xml
          push: cdata
        - match: '<\?'
          scope: punctuation.definition.tag.begin.xml
          push: processing_instruction
        - match: '<!(?:DOCTYPE|ENTITY|ELEMENT|ATTLIST)\b'
          scope: keyword.other.doctype.xml
          push: doctype
        - match: '(</?)([A-Za-z_][-A-Za-z_0-9.:]*)'
          captures:
            1: punctuation.definition.tag.begin.xml
            2: entity.name.tag.xml
          push: tag
        - match: '&(?:#\d+|#x\h+|[A-Za-z][A-Za-z0-9]*);'
          scope: constant.character.entity.xml
      comment:
        - meta_scope: comment.block.xml
        - match: '-->'
          pop: true
      cdata:
        - meta_scope: string.unquoted.cdata.xml
        - match: '\]\]>'
          scope: punctuation.definition.string.end.xml
          pop: true
      processing_instruction:
        - meta_scope: meta.tag.preprocessor.xml
        - match: '\?>'
          scope: punctuation.definition.tag.end.xml
          pop: true
      doctype:
        - meta_scope: meta.tag.sgml.xml
        - match: '>'
          pop: true
      tag:
        - meta_scope: meta.tag.xml
        - match: '/?>'
          scope: punctuation.definition.tag.end.xml
          pop: true
        - match: '[A-Za-z_][-A-Za-z_0-9.:]*'
          scope: entity.other.attribute-name.xml
        - match: '"'
          scope: punctuation.definition.string.begin.xml
          push: attribute_value
        - match: "'"
          scope: punctuation.definition.string.begin.xml
          push: attribute_value_single
      attribute_value:
        - meta_scope: string.quoted.double.xml
        - match: '"'
          scope: punctuation.definition.string.end.xml
          pop: true
      attribute_value_single:
        - meta_scope: string.quoted.single.xml
        - match: "'"
          scope: punctuation.definition.string.end.xml
          pop: true
    """#
}

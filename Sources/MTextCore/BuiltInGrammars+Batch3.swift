import Foundation

/// Batch 3 of Sublime grammar parity (T114, the long tail): ASP, ActionScript,
/// AppleScript, Batch File, D, Erlang, Graphviz, Groovy, LaTeX, Lisp, MATLAB, OCaml,
/// Pascal, ERB (Sublime's "Rails" package embeds Ruby in HTML the same way), Regular
/// Expressions, reStructuredText, Tcl, Textile. See `BuiltInGrammars` for the raw-string
/// convention.
///
/// Two items from Sublime's default list are deliberately not separate grammars here:
/// "Text" is exactly what `text.plain` already is, and "Rails" isn't a language of its
/// own — it's a set of Ruby/HTML/YAML/SQL embeddings, of which ERB is the one that
/// actually needs its own tokenizer (the rest are just Ruby, already covered).
public extension BuiltInGrammars {

    // MARK: - ASP (classic)

    static let asp = #"""
    %YAML 1.2
    ---
    name: ASP
    scope: text.asp
    file_extensions: [asp, aspx, asax, ascx]
    first_line_match: '^<%@'
    contexts:
      main:
        - match: '<%[@=]?'
          scope: punctuation.section.embedded.begin.asp
          push: asp_code
        - match: '</?[A-Za-z][A-Za-z0-9:_-]*'
          scope: entity.name.tag.asp
      asp_code:
        - match: '%>'
          scope: punctuation.section.embedded.end.asp
          pop: true
        - match: "'"
          scope: punctuation.definition.comment.asp
          push: line_comment
        - match: '\b(?:Dim|Set|End|If|Then|Else|ElseIf|Sub|Function|Do|Loop|While|Wend|For|Next|Call|Class|Public|Private|Const|Exit|On Error Resume Next|Option Explicit)\b'
          scope: keyword.control.asp
        - match: '\b(?:True|False|Nothing|Null|Empty|And|Or|Not|Xor|Is)\b'
          scope: constant.language.asp
        - match: '\b\d+(?:\.\d+)?\b'
          scope: constant.numeric.asp
        - match: '"'
          scope: punctuation.definition.string.begin.asp
          push: asp_string
      line_comment:
        - meta_scope: comment.line.apostrophe.asp
        - match: '(?=%>)|$'
          pop: true
      asp_string:
        - meta_scope: string.quoted.double.asp
        - match: '""'
          scope: constant.character.escape.asp
        - match: '"'
          scope: punctuation.definition.string.end.asp
          pop: true
        - match: '(?=%>)|$'
          pop: true
    """#

    // MARK: - ActionScript

    static let actionscript = #"""
    %YAML 1.2
    ---
    name: ActionScript
    scope: source.actionscript.3
    file_extensions: [as]
    variables:
      ident: '[A-Za-z_$][A-Za-z_$0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:package|import|class|interface|extends|implements|public|private|protected|internal|static|final|override|dynamic|native|function|var|const|new|return|if|else|for|each|in|while|do|switch|case|default|break|continue|try|catch|finally|throw|delete|typeof|instanceof)\b'
          scope: keyword.control.actionscript
        - match: '\b(?:true|false|null|undefined|this|super)\b'
          scope: constant.language.actionscript
        - match: '\b0[xX]\h[\h]*\b'
          scope: constant.numeric.hex.actionscript
        - match: '\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\b'
          scope: constant.numeric.actionscript
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.actionscript
        - match: '[-+*/%=<>!&|^~?:]+'
          scope: keyword.operator.actionscript
      comments:
        - match: '/\*'
          scope: punctuation.definition.comment.actionscript
          push: block_comment
        - match: '//'
          scope: punctuation.definition.comment.actionscript
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-slash.actionscript
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.actionscript
        - match: '\*/'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.actionscript
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.actionscript
          push: single_string
      double_string:
        - meta_scope: string.quoted.double.actionscript
        - match: '\\.'
          scope: constant.character.escape.actionscript
        - match: '"'
          scope: punctuation.definition.string.end.actionscript
          pop: true
        - match: '$'
          pop: true
      single_string:
        - meta_scope: string.quoted.single.actionscript
        - match: '\\.'
          scope: constant.character.escape.actionscript
        - match: "'"
          scope: punctuation.definition.string.end.actionscript
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - AppleScript

    static let applescript = #"""
    %YAML 1.2
    ---
    name: AppleScript
    scope: source.applescript
    file_extensions: [applescript, scpt]
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:end tell|end repeat|end try|end if|using terms from|missing value|tell|if|then|else|repeat|with|to|set|get|return|on|end|global|local|property|try|error|considering|ignoring)\b'
          scope: keyword.control.applescript
        - match: '\b(?:true|false|and|or|not|of|in|as|is|contains)\b'
          scope: constant.language.applescript
        - match: '\b\d+(?:\.\d+)?\b'
          scope: constant.numeric.applescript
      comments:
        - match: '\(\*'
          scope: punctuation.definition.comment.applescript
          push: block_comment
        - match: '--'
          scope: punctuation.definition.comment.applescript
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-dash.applescript
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.applescript
        - match: '\*\)'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.applescript
          push: double_string
      double_string:
        - meta_scope: string.quoted.double.applescript
        - match: '\\.'
          scope: constant.character.escape.applescript
        - match: '"'
          scope: punctuation.definition.string.end.applescript
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Batch File

    static let batchfile = #"""
    %YAML 1.2
    ---
    name: Batch File
    scope: source.batchfile
    file_extensions: [bat, cmd, btm]
    contexts:
      main:
        - match: '(?i)^\s*(?:rem\b.*|::.*)$'
          scope: comment.line.batchfile
        - match: '(?i)\b(?:echo|set|setlocal|endlocal|if|else|goto|call|exit|for|pause|cls|shift|start|title|cd|md|mkdir|rd|rmdir|del|copy|move|ren|exist|not|defined|errorlevel|do|in)\b'
          scope: keyword.control.batchfile
        - match: '^\s*:[A-Za-z_][A-Za-z0-9_-]*'
          scope: entity.name.label.batchfile
        - match: '%%?[A-Za-z_0-9~:.$]+%?'
          scope: variable.other.batchfile
        - match: '"'
          scope: punctuation.definition.string.begin.batchfile
          push: double_string
      double_string:
        - meta_scope: string.quoted.double.batchfile
        - match: '"'
          scope: punctuation.definition.string.end.batchfile
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - D

    static let d = #"""
    %YAML 1.2
    ---
    name: D
    scope: source.d
    file_extensions: [d, di]
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:module|import|class|struct|interface|enum|union|template|alias|auto|const|immutable|shared|static|public|private|protected|package|override|final|abstract|if|else|for|foreach|foreach_reverse|while|do|switch|case|default|break|continue|return|try|catch|finally|throw|scope|synchronized|mixin|version|debug)\b'
          scope: keyword.control.d
        - match: '\b(?:bool|byte|ubyte|short|ushort|int|uint|long|ulong|float|double|real|char|wchar|dchar|void|string|wstring|dstring|size_t)\b'
          scope: storage.type.primitive.d
        - match: '\b(?:true|false|null|this|super)\b'
          scope: constant.language.d
        - match: '\b0[xX]\h[\h_]*\b'
          scope: constant.numeric.hex.d
        - match: '\b\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?\b'
          scope: constant.numeric.d
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.d
        - match: '[-+*/%=<>!&|^~?:]+'
          scope: keyword.operator.d
      comments:
        - match: '/\*'
          scope: punctuation.definition.comment.d
          push: block_comment
        - match: '//'
          scope: punctuation.definition.comment.d
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-slash.d
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.d
        - match: '\*/'
          pop: true
      strings:
        - match: '`'
          scope: punctuation.definition.string.begin.d
          push: raw_string
        - match: '"'
          scope: punctuation.definition.string.begin.d
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.d
          push: char_literal
      raw_string:
        - meta_scope: string.quoted.raw.d
        - match: '`'
          scope: punctuation.definition.string.end.d
          pop: true
      double_string:
        - meta_scope: string.quoted.double.d
        - match: '\\.'
          scope: constant.character.escape.d
        - match: '"'
          scope: punctuation.definition.string.end.d
          pop: true
        - match: '$'
          pop: true
      char_literal:
        - meta_scope: string.quoted.single.d
        - match: '\\.'
          scope: constant.character.escape.d
        - match: "'"
          scope: punctuation.definition.string.end.d
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Erlang

    static let erlang = #"""
    %YAML 1.2
    ---
    name: Erlang
    scope: source.erlang
    file_extensions: [erl, hrl]
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '-\s*(?:module|export|import|define|record|include|include_lib|behaviour|spec|type)\b'
          scope: keyword.control.directive.erlang
        - match: '\b(?:if|case|of|end|when|receive|after|fun|begin|catch|try|throw|andalso|orelse|not|and|or|xor|div|rem|band|bor|bxor|bsl|bsr)\b'
          scope: keyword.control.erlang
        - match: '\b[A-Z_][A-Za-z0-9_]*\b'
          scope: variable.other.erlang
        - match: '\b\d+#[0-9A-Za-z]+\b'
          scope: constant.numeric.based.erlang
        - match: '\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\b'
          scope: constant.numeric.erlang
      comments:
        - match: '%'
          scope: punctuation.definition.comment.erlang
          push: line_comment
      line_comment:
        - meta_scope: comment.line.percentage.erlang
        - match: '$'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.erlang
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.erlang
          push: quoted_atom
      double_string:
        - meta_scope: string.quoted.double.erlang
        - match: '\\.'
          scope: constant.character.escape.erlang
        - match: '"'
          scope: punctuation.definition.string.end.erlang
          pop: true
        - match: '$'
          pop: true
      quoted_atom:
        - meta_scope: string.quoted.single.erlang
        - match: '\\.'
          scope: constant.character.escape.erlang
        - match: "'"
          scope: punctuation.definition.string.end.erlang
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Graphviz (DOT)

    static let dot = #"""
    %YAML 1.2
    ---
    name: Graphviz (DOT)
    scope: source.dot
    file_extensions: [dot, gv]
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:strict|graph|digraph|subgraph|node|edge)\b'
          scope: keyword.control.dot
        - match: '->|--'
          scope: keyword.operator.dot
        - match: '[\[\]]'
          scope: punctuation.section.attributes.dot
        - match: '\b\d+(?:\.\d+)?\b'
          scope: constant.numeric.dot
      comments:
        - match: '/\*'
          scope: punctuation.definition.comment.dot
          push: block_comment
        - match: '//|#'
          scope: punctuation.definition.comment.dot
          push: line_comment
      line_comment:
        - meta_scope: comment.line.dot
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.dot
        - match: '\*/'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.dot
          push: double_string
      double_string:
        - meta_scope: string.quoted.double.dot
        - match: '\\.'
          scope: constant.character.escape.dot
        - match: '"'
          scope: punctuation.definition.string.end.dot
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Groovy

    static let groovy = #"""
    %YAML 1.2
    ---
    name: Groovy
    scope: source.groovy
    file_extensions: [groovy, gradle, gvy, gy]
    variables:
      ident: '[A-Za-z_$][A-Za-z_$0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:package|import|class|interface|trait|enum|extends|implements|public|private|protected|static|final|abstract|synchronized|def|var|new|return|if|else|for|in|while|do|switch|case|default|break|continue|try|catch|finally|throw|assert|as)\b'
          scope: keyword.control.groovy
        - match: '\b(?:true|false|null|this|super|it)\b'
          scope: constant.language.groovy
        - match: '\b0[xX]\h[\h]*\b'
          scope: constant.numeric.hex.groovy
        - match: '\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\b'
          scope: constant.numeric.groovy
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.groovy
        - match: '[-+*/%=<>!&|^~?:]+'
          scope: keyword.operator.groovy
      comments:
        - match: '/\*'
          scope: punctuation.definition.comment.groovy
          push: block_comment
        - match: '//'
          scope: punctuation.definition.comment.groovy
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-slash.groovy
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.groovy
        - match: '\*/'
          pop: true
      strings:
        - match: "'''"
          scope: punctuation.definition.string.begin.groovy
          push: triple_single_string
        - match: '"""'
          scope: punctuation.definition.string.begin.groovy
          push: triple_double_string
        - match: '"'
          scope: punctuation.definition.string.begin.groovy
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.groovy
          push: single_string
      triple_single_string:
        - meta_scope: string.quoted.triple.single.groovy
        - match: "'''"
          scope: punctuation.definition.string.end.groovy
          pop: true
      triple_double_string:
        - meta_scope: string.quoted.triple.double.groovy
        - match: '"""'
          scope: punctuation.definition.string.end.groovy
          pop: true
      double_string:
        - meta_scope: string.quoted.double.groovy
        - match: '\\.'
          scope: constant.character.escape.groovy
        - match: '"'
          scope: punctuation.definition.string.end.groovy
          pop: true
        - match: '$'
          pop: true
      single_string:
        - meta_scope: string.quoted.single.groovy
        - match: '\\.'
          scope: constant.character.escape.groovy
        - match: "'"
          scope: punctuation.definition.string.end.groovy
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - LaTeX

    static let latex = #"""
    %YAML 1.2
    ---
    name: LaTeX
    scope: text.tex.latex
    file_extensions: [tex, latex, sty, cls, bib]
    contexts:
      main:
        - match: '%.*$'
          scope: comment.line.percentage.tex
        - match: '\\[A-Za-z]+'
          scope: keyword.control.tex
        - match: '\\.'
          scope: constant.character.escape.tex
        - match: '[{}]'
          scope: punctuation.section.group.tex
        - match: '\$\$?'
          scope: punctuation.definition.math.tex
    """#

    // MARK: - Lisp

    static let lisp = #"""
    %YAML 1.2
    ---
    name: Lisp
    scope: source.lisp
    file_extensions: [lisp, lsp, cl, asd]
    variables:
      ident: '[A-Za-z_!?*+<>=/.-][A-Za-z0-9_!?*+<>=/.-]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\('
          scope: punctuation.section.parens.begin.lisp
          push: form
        - match: '\)'
          scope: punctuation.section.parens.end.lisp
        - match: ':{{ident}}'
          scope: constant.other.keyword.lisp
        - match: '\bt\b|\bnil\b'
          scope: constant.language.lisp
        - match: '\b\d+(?:\.\d+)?\b'
          scope: constant.numeric.lisp
      form:
        - match: '\)'
          scope: punctuation.section.parens.end.lisp
          pop: true
        - match: '\blet\*'
          scope: keyword.control.lisp
        - match: '\b(?:defun|defvar|defparameter|defmacro|defclass|defmethod|defgeneric|let|lambda|quote|setq|setf|dolist|dotimes|loop|if|cond|when|unless|progn)\b'
          scope: keyword.control.lisp
        - include: main
      comments:
        - match: ';'
          scope: punctuation.definition.comment.lisp
          push: line_comment
      line_comment:
        - meta_scope: comment.line.semicolon.lisp
        - match: '$'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.lisp
          push: double_string
      double_string:
        - meta_scope: string.quoted.double.lisp
        - match: '\\.'
          scope: constant.character.escape.lisp
        - match: '"'
          scope: punctuation.definition.string.end.lisp
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - MATLAB

    static let matlab = #"""
    %YAML 1.2
    ---
    name: MATLAB
    scope: source.matlab
    file_extensions: [m]
    variables:
      ident: '[A-Za-z][A-Za-z0-9_]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:function|end|if|elseif|else|for|parfor|while|switch|case|otherwise|break|continue|return|try|catch|global|persistent|classdef|properties|methods|events|enumeration)\b'
          scope: keyword.control.matlab
        - match: '\b(?:true|false|Inf|NaN|pi|eps)\b'
          scope: constant.language.matlab
        - match: '\b0[xX]\h[\h]*\b'
          scope: constant.numeric.hex.matlab
        - match: '\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?[ij]?\b'
          scope: constant.numeric.matlab
        - match: '\.\^|\.\*|\./|[-+*/^=<>~&|]+'
          scope: keyword.operator.matlab
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.matlab
      comments:
        - match: '%\{\s*$'
          scope: punctuation.definition.comment.matlab
          push: block_comment
        - match: '%'
          scope: punctuation.definition.comment.matlab
          push: line_comment
      line_comment:
        - meta_scope: comment.line.percentage.matlab
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.matlab
        - match: '^\s*%\}\s*$'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.matlab
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.matlab
          push: single_string
      double_string:
        - meta_scope: string.quoted.double.matlab
        - match: '""'
          scope: constant.character.escape.matlab
        - match: '"'
          scope: punctuation.definition.string.end.matlab
          pop: true
        - match: '$'
          pop: true
      single_string:
        - meta_scope: string.quoted.single.matlab
        - match: "''"
          scope: constant.character.escape.matlab
        - match: "'"
          scope: punctuation.definition.string.end.matlab
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - OCaml

    static let ocaml = #"""
    %YAML 1.2
    ---
    name: OCaml
    scope: source.ocaml
    file_extensions: [ml, mli]
    variables:
      ident: '[a-z_][A-Za-z_0-9'']*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:let|rec|in|fun|function|match|with|if|then|else|begin|end|type|of|module|struct|sig|open|exception|try|raise|and|mutable|ref|do|done|for|while|to|downto)\b'
          scope: keyword.control.ocaml
        - match: '\b(?:true|false)\b'
          scope: constant.language.ocaml
        - match: '\b([A-Z]{{ident}})\b'
          scope: entity.name.type.ocaml
        - match: '->|<-|::|[-+*/=<>!&|^~?:]+'
          scope: keyword.operator.ocaml
        - match: '\b0[xX]\h[\h]*\b'
          scope: constant.numeric.hex.ocaml
        - match: '\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\b'
          scope: constant.numeric.ocaml
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.ocaml
      comments:
        - match: '\(\*'
          scope: punctuation.definition.comment.ocaml
          push: block_comment
      block_comment:
        - meta_scope: comment.block.ocaml
        - match: '\*\)'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.ocaml
          push: double_string
      double_string:
        - meta_scope: string.quoted.double.ocaml
        - match: '\\.'
          scope: constant.character.escape.ocaml
        - match: '"'
          scope: punctuation.definition.string.end.ocaml
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Pascal

    static let pascal = #"""
    %YAML 1.2
    ---
    name: Pascal
    scope: source.pascal
    file_extensions: [pas, pp, inc, lpr]
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '(?i)\b(?:program|unit|uses|begin|end|var|const|type|procedure|function|if|then|else|case|of|for|to|downto|do|while|repeat|until|record|array|set|with|try|except|finally|class|interface|implementation|inherited|override|virtual|private|public|protected)\b'
          scope: keyword.control.pascal
        - match: '(?i)\b(?:true|false|nil)\b'
          scope: constant.language.pascal
        - match: '\$\h[\h]*\b'
          scope: constant.numeric.hex.pascal
        - match: '\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\b'
          scope: constant.numeric.pascal
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.pascal
      comments:
        - match: '\{'
          scope: punctuation.definition.comment.pascal
          push: brace_comment
        - match: '\(\*'
          scope: punctuation.definition.comment.pascal
          push: paren_comment
        - match: '//'
          scope: punctuation.definition.comment.pascal
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-slash.pascal
        - match: '$'
          pop: true
      brace_comment:
        - meta_scope: comment.block.pascal
        - match: '\}'
          pop: true
      paren_comment:
        - meta_scope: comment.block.pascal
        - match: '\*\)'
          pop: true
      strings:
        - match: "'"
          scope: punctuation.definition.string.begin.pascal
          push: single_string
      single_string:
        - meta_scope: string.quoted.single.pascal
        - match: "''"
          scope: constant.character.escape.pascal
        - match: "'"
          scope: punctuation.definition.string.end.pascal
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - ERB (Sublime's "Rails" package)

    static let erb = #"""
    %YAML 1.2
    ---
    name: HTML (Rails, ERB)
    scope: text.html.ruby
    file_extensions: [erb, rhtml, "html.erb"]
    contexts:
      main:
        - match: '<%={0,2}#'
          scope: punctuation.definition.comment.erb
          push: erb_comment
        - match: '<%={0,2}'
          scope: punctuation.section.embedded.begin.erb
          push: erb_code
        - match: '<!--'
          scope: punctuation.definition.comment.html
          push: html_comment
        - match: '</?[A-Za-z][A-Za-z0-9:_-]*'
          scope: entity.name.tag.html
      erb_comment:
        - meta_scope: comment.block.erb
        - match: '%>'
          scope: punctuation.section.embedded.end.erb
          pop: true
        - match: '$'
          pop: true
      html_comment:
        - meta_scope: comment.block.html
        - match: '-->'
          pop: true
      erb_code:
        - match: '%>'
          scope: punctuation.section.embedded.end.erb
          pop: true
        - match: '#.*(?=%>)|#.*$'
          scope: comment.line.number-sign.ruby
        - match: '\b(?:def|end|if|elsif|else|unless|while|until|for|in|do|class|module|begin|rescue|ensure|yield|return|case|when|then|render|content_for)\b'
          scope: keyword.control.ruby
        - match: '\b(?:true|false|nil|self)\b'
          scope: constant.language.ruby
        - match: '@{1,2}[A-Za-z_][A-Za-z0-9_]*'
          scope: variable.other.instance.ruby
        - match: ':[A-Za-z_][A-Za-z0-9_]*'
          scope: constant.other.symbol.ruby
        - match: '"'
          scope: punctuation.definition.string.begin.ruby
          push: erb_double_string
        - match: "'"
          scope: punctuation.definition.string.begin.ruby
          push: erb_single_string
      erb_double_string:
        - meta_scope: string.quoted.double.ruby
        - match: '\\.'
          scope: constant.character.escape.ruby
        - match: '"'
          scope: punctuation.definition.string.end.ruby
          pop: true
        - match: '(?=%>)'
          pop: true
      erb_single_string:
        - meta_scope: string.quoted.single.ruby
        - match: '\\.'
          scope: constant.character.escape.ruby
        - match: "'"
          scope: punctuation.definition.string.end.ruby
          pop: true
        - match: '(?=%>)'
          pop: true
    """#

    // MARK: - Regular Expressions

    static let regexp = #"""
    %YAML 1.2
    ---
    name: Regular Expressions
    scope: source.regexp
    file_extensions: [re, regexp]
    contexts:
      main:
        - match: '\\.'
          scope: constant.character.escape.regexp
        - match: '\(\?[:=!<]?'
          scope: punctuation.definition.group.regexp
        - match: '[()]'
          scope: punctuation.section.group.regexp
        - match: '\[\^?'
          scope: punctuation.definition.character-class.begin.regexp
          push: character_class
        - match: '[*+?]|\{\d+(?:,\d*)?\}'
          scope: keyword.operator.quantifier.regexp
        - match: '[|^$.]'
          scope: keyword.operator.regexp
      character_class:
        - meta_scope: string.regexp.character-class.regexp
        - match: '\\.'
          scope: constant.character.escape.regexp
        - match: '\]'
          scope: punctuation.definition.character-class.end.regexp
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - reStructuredText

    static let restructuredtext = #"""
    %YAML 1.2
    ---
    name: reStructuredText
    scope: text.restructuredtext
    file_extensions: [rst, rest]
    contexts:
      main:
        - match: '^\.\.\s+[A-Za-z][A-Za-z0-9_-]*::'
          scope: keyword.control.directive.restructuredtext
        - match: '^[=\-~^"''#*+.:_`]{3,}\s*$'
          scope: markup.heading.restructuredtext
        - match: '\*\*[^*]+\*\*'
          scope: markup.bold.restructuredtext
        - match: '\*[^*]+\*'
          scope: markup.italic.restructuredtext
        - match: '``[^`]+``'
          scope: markup.raw.restructuredtext
        - match: '`[^`]+`_{0,2}'
          scope: markup.underline.link.restructuredtext
    """#

    // MARK: - Tcl

    static let tcl = #"""
    %YAML 1.2
    ---
    name: Tcl
    scope: source.tcl
    file_extensions: [tcl, tk, itcl]
    first_line_match: '^#!.*\btclsh\b'
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - match: '#.*$'
          scope: comment.line.number-sign.tcl
        - match: '\b(?:if|elseif|else|while|for|foreach|switch|proc|return|break|continue|catch|uplevel|upvar|global|set|expr|eval|source|namespace|package|variable|incr|append|lappend)\b'
          scope: keyword.control.tcl
        - match: '\$\{?{{ident}}\}?'
          scope: variable.other.tcl
        - match: '\b\d+(?:\.\d+)?\b'
          scope: constant.numeric.tcl
        - match: '"'
          scope: punctuation.definition.string.begin.tcl
          push: double_string
        - match: '\['
          scope: punctuation.section.embedded.begin.tcl
          push: bracket_eval
      bracket_eval:
        - match: '\]'
          scope: punctuation.section.embedded.end.tcl
          pop: true
        - include: main
      double_string:
        - meta_scope: string.quoted.double.tcl
        - match: '\\.'
          scope: constant.character.escape.tcl
        - match: '"'
          scope: punctuation.definition.string.end.tcl
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Textile

    static let textile = #"""
    %YAML 1.2
    ---
    name: Textile
    scope: text.html.textile
    file_extensions: [textile]
    contexts:
      main:
        - match: '^h[1-6]\.\s'
          scope: markup.heading.textile
        - match: '^\*\s'
          scope: markup.list.textile
        - match: '^#\s'
          scope: markup.list.textile
        - match: '\*[^*]+\*'
          scope: markup.bold.textile
        - match: '_[^_]+_'
          scope: markup.italic.textile
        - match: '\?\?[^?]+\?\?'
          scope: markup.italic.citation.textile
        - match: '"[^"]+":\S+'
          scope: markup.underline.link.textile
    """#
}

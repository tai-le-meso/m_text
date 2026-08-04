import Foundation

/// Batch 2 of Sublime grammar parity (T113): Lua, Makefile, Diff, TOML, R, Haskell,
/// Scala, Clojure. See `BuiltInGrammars` for the raw-string convention.
public extension BuiltInGrammars {

    // MARK: - Lua

    static let lua = #"""
    %YAML 1.2
    ---
    name: Lua
    scope: source.lua
    file_extensions: [lua]
    first_line_match: '^#!.*\blua\b'
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:and|break|do|else|elseif|end|false|for|function|goto|if|in|local|nil|not|or|repeat|return|then|true|until|while)\b'
          scope: keyword.control.lua
        - match: '\bself\b'
          scope: variable.language.lua
        - match: '\bfunction\s+({{ident}}(?:[.:]{{ident}})*)'
          captures:
            1: entity.name.function.lua
        - match: '\b0[xX]\h[\h]*\b'
          scope: constant.numeric.hex.lua
        - match: '\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\b'
          scope: constant.numeric.lua
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.lua
        - match: '\.\.\.|\.\.|[-+*/%^#=<>~]+'
          scope: keyword.operator.lua
      comments:
        - match: '--\[=*\['
          scope: punctuation.definition.comment.lua
          push: block_comment
        - match: '--'
          scope: punctuation.definition.comment.lua
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-dash.lua
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.lua
        - match: '\]=*\]'
          pop: true
      strings:
        - match: '\[=*\['
          scope: punctuation.definition.string.begin.lua
          push: long_string
        - match: '"'
          scope: punctuation.definition.string.begin.lua
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.lua
          push: single_string
      long_string:
        - meta_scope: string.quoted.other.multiline.lua
        - match: '\]=*\]'
          scope: punctuation.definition.string.end.lua
          pop: true
      double_string:
        - meta_scope: string.quoted.double.lua
        - match: '\\.'
          scope: constant.character.escape.lua
        - match: '"'
          scope: punctuation.definition.string.end.lua
          pop: true
        - match: '$'
          pop: true
      single_string:
        - meta_scope: string.quoted.single.lua
        - match: '\\.'
          scope: constant.character.escape.lua
        - match: "'"
          scope: punctuation.definition.string.end.lua
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Makefile

    static let makefile = #"""
    %YAML 1.2
    ---
    name: Makefile
    scope: source.makefile
    file_extensions: [mk, mak, makefile, gnumakefile, "makefile.am", "makefile.in"]
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - match: '^#.*$'
          scope: comment.line.number-sign.makefile
        - match: '^\s*(?:ifeq|ifneq|ifdef|ifndef|else|endif|include|-include|sinclude|define|endef|export|unexport|override|vpath|undefine)\b'
          scope: keyword.control.directive.makefile
        - match: '\$[@^<*?%+|]'
          scope: variable.language.automatic.makefile
        - match: '\$\(|\$\{'
          scope: punctuation.definition.variable.begin.makefile
          push: variable_ref
        - match: '^\s*({{ident}})\s*(:{2}|[!?:+]?=)'
          captures:
            1: variable.other.makefile
            2: keyword.operator.assignment.makefile
        - match: '^([^\t:#=\n][^:#=\n]*):(?!=)'
          captures:
            1: entity.name.function.target.makefile
        - match: '"'
          scope: punctuation.definition.string.begin.makefile
          push: double_string
      variable_ref:
        - meta_scope: variable.other.makefile
        - match: '\)|\}'
          scope: punctuation.definition.variable.end.makefile
          pop: true
        - match: '$'
          pop: true
      double_string:
        - meta_scope: string.quoted.double.makefile
        - match: '\\.'
          scope: constant.character.escape.makefile
        - match: '"'
          scope: punctuation.definition.string.end.makefile
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Diff

    static let diff = #"""
    %YAML 1.2
    ---
    name: Diff
    scope: source.diff
    file_extensions: [diff, patch, rej]
    first_line_match: '^(?:diff\b|---\s|\*\*\*\s|Index:\s)'
    contexts:
      main:
        - match: '^diff\b.*$'
          scope: meta.diff.header.command.diff
        - match: '^Index:.*$'
          scope: meta.diff.header.index.diff
        - match: '^={4,}.*$'
          scope: meta.diff.separator.diff
        - match: '^---\s.*$'
          scope: meta.diff.header.from-file.diff
        - match: '^\+{3}\s.*$'
          scope: meta.diff.header.to-file.diff
        - match: '^\*{3}\s.*$'
          scope: meta.diff.header.from-file.diff
        - match: '^@@.*@@.*$'
          scope: meta.diff.range.unified.diff
        - match: '^\*{15}.*$'
          scope: meta.diff.range.context.diff
        - match: '^\+.*$'
          scope: markup.inserted.diff
        - match: '^-.*$'
          scope: markup.deleted.diff
        - match: '^!.*$'
          scope: markup.changed.diff
        - match: '^\\ No newline at end of file\s*$'
          scope: comment.line.diff
    """#

    // MARK: - TOML

    static let toml = #"""
    %YAML 1.2
    ---
    name: TOML
    scope: source.toml
    file_extensions: [toml]
    contexts:
      main:
        - match: '#.*$'
          scope: comment.line.number-sign.toml
        - match: '^\s*(\[\[?)([^\[\]]+)(\]\]?)'
          captures:
            1: punctuation.definition.section.begin.toml
            2: entity.name.section.toml
            3: punctuation.definition.section.end.toml
        - match: '\b(?:true|false)\b'
          scope: constant.language.boolean.toml
        - match: '\b\d{4}-\d{2}-\d{2}(?:[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[-+]\d{2}:\d{2})?)?\b'
          scope: constant.other.date.toml
        - match: '\b0[xX][0-9A-Fa-f_]+\b'
          scope: constant.numeric.hex.toml
        - match: '\b0[oO][0-7_]+\b'
          scope: constant.numeric.octal.toml
        - match: '\b0[bB][01_]+\b'
          scope: constant.numeric.binary.toml
        - match: '[+-]?\b\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?\b'
          scope: constant.numeric.toml
        - match: '^\s*([A-Za-z0-9_.-]+|"[^"]*"|''[^'']*'')\s*(=)'
          captures:
            1: entity.name.tag.key.toml
            2: punctuation.separator.key-value.toml
        - match: '"""'
          scope: punctuation.definition.string.begin.toml
          push: multiline_double_string
        - match: "'''"
          scope: punctuation.definition.string.begin.toml
          push: multiline_single_string
        - match: '"'
          scope: punctuation.definition.string.begin.toml
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.toml
          push: single_string
      multiline_double_string:
        - meta_scope: string.quoted.double.multiline.toml
        - match: '\\.'
          scope: constant.character.escape.toml
        - match: '"""'
          scope: punctuation.definition.string.end.toml
          pop: true
      multiline_single_string:
        - meta_scope: string.quoted.single.multiline.toml
        - match: "'''"
          scope: punctuation.definition.string.end.toml
          pop: true
      double_string:
        - meta_scope: string.quoted.double.toml
        - match: '\\.'
          scope: constant.character.escape.toml
        - match: '"'
          scope: punctuation.definition.string.end.toml
          pop: true
        - match: '$'
          pop: true
      single_string:
        - meta_scope: string.quoted.single.toml
        - match: "'"
          scope: punctuation.definition.string.end.toml
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - R

    static let r = #"""
    %YAML 1.2
    ---
    name: R
    scope: source.r
    file_extensions: [r, "R", rdata, rds, rda]
    first_line_match: '^#!.*\bRscript\b'
    variables:
      ident: '[A-Za-z.][A-Za-z0-9._]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:if|else|repeat|while|function|for|in|next|break)\b'
          scope: keyword.control.r
        - match: '\b(?:TRUE|FALSE|NULL|NA|NA_integer_|NA_real_|NA_character_|NA_complex_|Inf|NaN)\b'
          scope: constant.language.r
        - match: '<<-|<-|->>|->|='
          scope: keyword.operator.assignment.r
        - match: '%[A-Za-z.]*%|::?:?|[-+*/^!&|<>=~]+'
          scope: keyword.operator.r
        - match: '\b0[xX]\h[\h]*[Li]?\b'
          scope: constant.numeric.hex.r
        - match: '\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?[Li]?\b'
          scope: constant.numeric.r
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.r
      comments:
        - match: '#'
          scope: punctuation.definition.comment.r
          push: line_comment
      line_comment:
        - meta_scope: comment.line.number-sign.r
        - match: '$'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.r
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.r
          push: single_string
        - match: '`'
          scope: punctuation.definition.variable.begin.r
          push: backtick_name
      double_string:
        - meta_scope: string.quoted.double.r
        - match: '\\.'
          scope: constant.character.escape.r
        - match: '"'
          scope: punctuation.definition.string.end.r
          pop: true
        - match: '$'
          pop: true
      single_string:
        - meta_scope: string.quoted.single.r
        - match: '\\.'
          scope: constant.character.escape.r
        - match: "'"
          scope: punctuation.definition.string.end.r
          pop: true
        - match: '$'
          pop: true
      backtick_name:
        - meta_scope: variable.other.backtick.r
        - match: '`'
          scope: punctuation.definition.variable.end.r
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Haskell

    static let haskell = #"""
    %YAML 1.2
    ---
    name: Haskell
    scope: source.haskell
    file_extensions: [hs, lhs]
    variables:
      ident: '[a-z_][A-Za-z_0-9'']*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:module|where|import|qualified|as|hiding|data|type|newtype|class|instance|deriving|do|case|of|let|in|if|then|else|infix|infixl|infixr)\b'
          scope: keyword.control.haskell
        - match: '\b([A-Z][A-Za-z0-9_'']*)\b'
          scope: entity.name.type.haskell
        - match: '->|<-|::|=>|\||\\'
          scope: keyword.operator.haskell
        - match: '\b0[xX]\h[\h]*\b'
          scope: constant.numeric.hex.haskell
        - match: '\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\b'
          scope: constant.numeric.haskell
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.haskell
      comments:
        - match: '\{-'
          scope: punctuation.definition.comment.haskell
          push: block_comment
        - match: '--'
          scope: punctuation.definition.comment.haskell
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-dash.haskell
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.haskell
        - match: '-\}'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.haskell
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.haskell
          push: char_literal
      double_string:
        - meta_scope: string.quoted.double.haskell
        - match: '\\.'
          scope: constant.character.escape.haskell
        - match: '"'
          scope: punctuation.definition.string.end.haskell
          pop: true
        - match: '$'
          pop: true
      char_literal:
        - meta_scope: string.quoted.single.haskell
        - match: '\\.'
          scope: constant.character.escape.haskell
        - match: "'"
          scope: punctuation.definition.string.end.haskell
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Scala

    static let scala = #"""
    %YAML 1.2
    ---
    name: Scala
    scope: source.scala
    file_extensions: [scala, sc, sbt]
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:abstract|case|catch|class|def|do|else|extends|final|finally|for|forSome|if|implicit|import|lazy|match|new|null|object|override|package|private|protected|return|sealed|super|this|throw|trait|try|type|val|var|while|with|yield)\b'
          scope: keyword.control.scala
        - match: '\b(?:true|false)\b'
          scope: constant.language.scala
        - match: '=>|<-|<:|>:|::|[-+*/%=<>!&|^~?:@]+'
          scope: keyword.operator.scala
        - match: '\b0[xX]\h[\h]*\b'
          scope: constant.numeric.hex.scala
        - match: '\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?[fFdDlL]?\b'
          scope: constant.numeric.scala
        - match: '\b([A-Z]{{ident}})\b'
          scope: entity.name.type.scala
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.scala
      comments:
        - match: '/\*'
          scope: punctuation.definition.comment.scala
          push: block_comment
        - match: '//'
          scope: punctuation.definition.comment.scala
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-slash.scala
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.scala
        - match: '\*/'
          pop: true
      strings:
        - match: '"""'
          scope: punctuation.definition.string.begin.scala
          push: triple_string
        - match: '"'
          scope: punctuation.definition.string.begin.scala
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.scala
          push: char_literal
      triple_string:
        - meta_scope: string.quoted.triple.scala
        - match: '"""'
          scope: punctuation.definition.string.end.scala
          pop: true
      double_string:
        - meta_scope: string.quoted.double.scala
        - match: '\\.'
          scope: constant.character.escape.scala
        - match: '"'
          scope: punctuation.definition.string.end.scala
          pop: true
        - match: '$'
          pop: true
      char_literal:
        - meta_scope: string.quoted.single.scala
        - match: '\\.'
          scope: constant.character.escape.scala
        - match: "'"
          scope: punctuation.definition.string.end.scala
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Clojure

    static let clojure = #"""
    %YAML 1.2
    ---
    name: Clojure
    scope: source.clojure
    file_extensions: [clj, cljs, cljc, edn]
    variables:
      ident: '[A-Za-z_!?*+<>=/.-][A-Za-z0-9_!?*+<>=/.-]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\('
          scope: punctuation.section.parens.begin.clojure
          push: form
        - match: '\['
          scope: punctuation.section.brackets.begin.clojure
        - match: '\]'
          scope: punctuation.section.brackets.end.clojure
        - match: '\{'
          scope: punctuation.section.braces.begin.clojure
        - match: '\}'
          scope: punctuation.section.braces.end.clojure
        - match: '::?{{ident}}'
          scope: constant.other.keyword.clojure
        - match: '\b(?:true|false|nil)\b'
          scope: constant.language.clojure
        - match: '\\.'
          scope: constant.character.clojure
        - match: '\b\d+(?:\.\d+)?\b'
          scope: constant.numeric.clojure
      form:
        - match: '\)'
          scope: punctuation.section.parens.end.clojure
          pop: true
        - match: '\bdefn-'
          scope: keyword.control.clojure
        - match: '\b(?:if-let|if-not|when-let|when-not|def|defn|defmacro|defprotocol|defrecord|deftype|defmulti|defmethod|let|letfn|fn|if|when|do|loop|recur|cond|condp|case|ns|require|import|use|quote|var|throw|try|catch|finally|and|or|not)\b'
          scope: keyword.control.clojure
        - include: main
      comments:
        - match: ';'
          scope: punctuation.definition.comment.clojure
          push: line_comment
      line_comment:
        - meta_scope: comment.line.semicolon.clojure
        - match: '$'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.clojure
          push: double_string
      double_string:
        - meta_scope: string.quoted.double.clojure
        - match: '\\.'
          scope: constant.character.escape.clojure
        - match: '"'
          scope: punctuation.definition.string.end.clojure
          pop: true
        - match: '$'
          pop: true
    """#
}

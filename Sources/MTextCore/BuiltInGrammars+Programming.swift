import Foundation

/// Programming-language grammars. See `BuiltInGrammars` for the raw-string convention.
public extension BuiltInGrammars {

    // MARK: - Java

    /// Covers Spring codebases: annotations, generics, records, sealed types, text blocks.
    static let java = #"""
    %YAML 1.2
    ---
    name: Java
    scope: source.java
    file_extensions: [java, jav]
    variables:
      ident: '[A-Za-z_$][A-Za-z_$0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - include: annotations
        - match: '\b(?:class|interface|enum|record|@interface)\b'
          scope: storage.type.class.java
          push: type_name
        - match: '\b(?:extends|implements|permits|sealed|non-sealed)\b'
          scope: storage.modifier.java
        - match: '\b(?:public|private|protected|static|final|abstract|native|synchronized|transient|volatile|strictfp|default)\b'
          scope: storage.modifier.java
        - match: '\b(?:if|else|for|while|do|switch|case|default|break|continue|return|yield|try|catch|finally|throw|throws|assert|instanceof|new)\b'
          scope: keyword.control.java
        - match: '\b(?:package|import)\b'
          scope: keyword.other.import.java
        - match: '\b(?:void|boolean|byte|char|short|int|long|float|double|var)\b'
          scope: storage.type.primitive.java
        - match: '\b(?:true|false|null)\b'
          scope: constant.language.java
        - match: '\b(?:this|super)\b'
          scope: variable.language.java
        - match: '\b0[xX]\h[\h_]*[lL]?\b'
          scope: constant.numeric.hex.java
        - match: '\b0[bB][01][01_]*[lL]?\b'
          scope: constant.numeric.binary.java
        - match: '\b\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?[fFdDlL]?\b'
          scope: constant.numeric.java
        - match: '\b([A-Z][A-Z0-9_]{2,})\b'
          scope: constant.other.java
        - match: '\b([A-Z]{{ident}})\b'
          scope: entity.name.type.java
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.java
        - match: '[-+*/%=<>!&|^~?:]+'
          scope: keyword.operator.java
      type_name:
        - match: '{{ident}}'
          scope: entity.name.type.class.java
          pop: true
        - match: '(?=\S)'
          pop: true
      annotations:
        - match: '(@{{ident}}(?:\.{{ident}})*)'
          scope: storage.modifier.annotation.java
      comments:
        - match: '/\*\*'
          scope: punctuation.definition.comment.java
          push: javadoc
        - match: '/\*'
          scope: punctuation.definition.comment.java
          push: block_comment
        - match: '//'
          scope: punctuation.definition.comment.java
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-slash.java
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.java
        - match: '\*/'
          pop: true
      javadoc:
        - meta_scope: comment.block.documentation.java
        - match: '@(?:param|return|throws|exception|see|since|author|deprecated|link|code|inheritDoc)\b'
          scope: keyword.other.documentation.java
        - match: '\*/'
          pop: true
      strings:
        - match: '"""'
          scope: punctuation.definition.string.begin.java
          push: text_block
        - match: '"'
          scope: punctuation.definition.string.begin.java
          push: quoted_string
        - match: "'"
          scope: punctuation.definition.string.begin.java
          push: char_literal
      quoted_string:
        - meta_scope: string.quoted.double.java
        - match: '\\(?:[btnfr"''\\]|u\h{4}|[0-7]{1,3})'
          scope: constant.character.escape.java
        - match: '"'
          scope: punctuation.definition.string.end.java
          pop: true
        - match: '$'
          pop: true
      text_block:
        - meta_scope: string.quoted.triple.java
        - match: '\\(?:[btnfr"''\\s]|u\h{4})'
          scope: constant.character.escape.java
        - match: '"""'
          scope: punctuation.definition.string.end.java
          pop: true
      char_literal:
        - meta_scope: string.quoted.single.java
        - match: '\\(?:[btnfr"''\\]|u\h{4}|[0-7]{1,3})'
          scope: constant.character.escape.java
        - match: "'"
          scope: punctuation.definition.string.end.java
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Swift

    static let swift = #"""
    %YAML 1.2
    ---
    name: Swift
    scope: source.swift
    file_extensions: [swift]
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:class|struct|enum|protocol|extension|actor|typealias|associatedtype)\b'
          scope: storage.type.swift
        - match: '\b(?:func|init|deinit|subscript|willSet|didSet|get|set)\b'
          scope: storage.type.function.swift
        - match: '\b(?:let|var|inout|lazy|weak|unowned|static|final|override|mutating|nonmutating|indirect|dynamic|convenience|required|open|public|internal|fileprivate|private|package)\b'
          scope: storage.modifier.swift
        - match: '\b(?:if|else|guard|switch|case|default|for|while|repeat|do|catch|throw|throws|rethrows|try|return|break|continue|fallthrough|defer|where|in|async|await|some|any)\b'
          scope: keyword.control.swift
        - match: '\b(?:import|as|is|nil|self|Self|super)\b'
          scope: keyword.other.swift
        - match: '\b(?:true|false)\b'
          scope: constant.language.boolean.swift
        - match: '@{{ident}}'
          scope: storage.modifier.attribute.swift
        - match: '#{{ident}}'
          scope: keyword.other.directive.swift
        - match: '\b0x\h[\h_]*\b'
          scope: constant.numeric.hex.swift
        - match: '\b0b[01][01_]*\b'
          scope: constant.numeric.binary.swift
        - match: '\b\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?\b'
          scope: constant.numeric.swift
        - match: '\b([A-Z]{{ident}})\b'
          scope: entity.name.type.swift
        - match: '\b({{ident}})(?=\s*\()'
          scope: support.function.swift
        - match: '[-+*/%=<>!&|^~?]+'
          scope: keyword.operator.swift
      comments:
        - match: '//'
          scope: punctuation.definition.comment.swift
          push: line_comment
        - match: '/\*'
          scope: punctuation.definition.comment.swift
          push: block_comment
      line_comment:
        - meta_scope: comment.line.double-slash.swift
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.swift
        - match: '\*/'
          pop: true
      strings:
        - match: '"""'
          scope: punctuation.definition.string.begin.swift
          push: multiline_string
        - match: '"'
          scope: punctuation.definition.string.begin.swift
          push: quoted_string
      quoted_string:
        - meta_scope: string.quoted.double.swift
        - match: '\\\('
          scope: punctuation.section.interpolation.begin.swift
          push: interpolation
        - match: '\\(?:[0nrt"''\\]|u\{\h{1,8}\})'
          scope: constant.character.escape.swift
        - match: '"'
          scope: punctuation.definition.string.end.swift
          pop: true
        - match: '$'
          pop: true
      multiline_string:
        - meta_scope: string.quoted.triple.swift
        - match: '\\\('
          scope: punctuation.section.interpolation.begin.swift
          push: interpolation
        - match: '"""'
          scope: punctuation.definition.string.end.swift
          pop: true
      interpolation:
        - meta_scope: meta.interpolation.swift
        - match: '\)'
          scope: punctuation.section.interpolation.end.swift
          pop: true
        - include: main
    """#

    // MARK: - Python

    static let python = #"""
    %YAML 1.2
    ---
    name: Python
    scope: source.python
    file_extensions: [py, pyw, pyi]
    first_line_match: '^#!.*\bpython'
    contexts:
      main:
        - match: '#'
          scope: punctuation.definition.comment.python
          push: comment
        - match: '"""'
          scope: punctuation.definition.string.begin.python
          push: docstring
        - match: '[uUbBrRfF]{0,2}"'
          scope: punctuation.definition.string.begin.python
          push: double_string
        - match: "[uUbBrRfF]{0,2}'"
          scope: punctuation.definition.string.begin.python
          push: single_string
        - match: '\b(?:def|class|lambda)\b'
          scope: storage.type.python
        - match: '\b(?:if|elif|else|for|while|break|continue|pass|return|yield|try|except|finally|raise|with|as|assert|del|global|nonlocal|import|from|async|await|match|case)\b'
          scope: keyword.control.python
        - match: '\b(?:and|or|not|in|is)\b'
          scope: keyword.operator.logical.python
        - match: '\b(?:True|False|None)\b'
          scope: constant.language.python
        - match: '\b(?:self|cls)\b'
          scope: variable.language.python
        - match: '@[A-Za-z_][A-Za-z_0-9.]*'
          scope: entity.name.function.decorator.python
        - match: '\b(?:print|len|range|enumerate|zip|map|filter|open|isinstance|super|int|str|float|bool|list|dict|set|tuple)\b'
          scope: support.function.builtin.python
        - match: '\b0[xX]\h[\h_]*\b'
          scope: constant.numeric.hex.python
        - match: '\b\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?[jJ]?\b'
          scope: constant.numeric.python
      comment:
        - meta_scope: comment.line.number-sign.python
        - match: '$'
          pop: true
      docstring:
        - meta_scope: string.quoted.docstring.python
        - match: '"""'
          scope: punctuation.definition.string.end.python
          pop: true
      double_string:
        - meta_scope: string.quoted.double.python
        - match: '\\.'
          scope: constant.character.escape.python
        - match: '"'
          scope: punctuation.definition.string.end.python
          pop: true
        - match: '$'
          pop: true
      single_string:
        - meta_scope: string.quoted.single.python
        - match: '\\.'
          scope: constant.character.escape.python
        - match: "'"
          scope: punctuation.definition.string.end.python
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Shell

    static let shell = #"""
    %YAML 1.2
    ---
    name: Shell Script
    scope: source.shell
    file_extensions: [sh, bash, zsh, bashrc, zshrc, profile, command, zprofile]
    first_line_match: '^#!.*\b(?:ba|z|k)?sh\b'
    contexts:
      main:
        - match: '#'
          scope: punctuation.definition.comment.shell
          push: comment
        - match: '"'
          scope: punctuation.definition.string.begin.shell
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.shell
          push: single_string
        - match: '\b(?:if|then|else|elif|fi|for|while|until|do|done|case|esac|in|function|select|time|return|break|continue)\b'
          scope: keyword.control.shell
        - match: '\b(?:echo|cd|export|source|local|readonly|unset|shift|exit|eval|exec|trap|set|test|printf|read)\b'
          scope: support.function.builtin.shell
        - match: '\$(?:\{[^}]*\}|[A-Za-z_][A-Za-z_0-9]*|[0-9@*#?$!-])'
          scope: variable.other.shell
        - match: '[|&;><]+'
          scope: keyword.operator.shell
      comment:
        - meta_scope: comment.line.number-sign.shell
        - match: '$'
          pop: true
      double_string:
        - meta_scope: string.quoted.double.shell
        - match: '\\.'
          scope: constant.character.escape.shell
        - match: '\$(?:\{[^}]*\}|[A-Za-z_][A-Za-z_0-9]*)'
          scope: variable.other.shell
        - match: '"'
          scope: punctuation.definition.string.end.shell
          pop: true
      single_string:
        - meta_scope: string.quoted.single.shell
        - match: "'"
          scope: punctuation.definition.string.end.shell
          pop: true
    """#
}

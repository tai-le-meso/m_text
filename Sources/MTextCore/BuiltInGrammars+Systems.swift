import Foundation

/// C-family and systems-language grammars. See `BuiltInGrammars` for the raw-string
/// convention.
public extension BuiltInGrammars {

    // MARK: - C

    static let c = #"""
    %YAML 1.2
    ---
    name: C
    scope: source.c
    file_extensions: [c, h]
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '^\s*#\s*include\b'
          scope: keyword.control.import.c
          push: include_line
        - match: '^\s*#\s*(?:define|ifdef|ifndef|if|else|elif|endif|undef|pragma|error|line)\b'
          scope: keyword.control.import.c
        - match: '\b(?:if|else|for|while|do|switch|case|default|break|continue|return|goto|sizeof)\b'
          scope: keyword.control.c
        - match: '\b(?:typedef|struct|union|enum|auto|register|static|extern|const|volatile|inline|restrict)\b'
          scope: storage.modifier.c
        - match: '\b(?:void|char|short|int|long|float|double|signed|unsigned|_Bool)\b'
          scope: storage.type.primitive.c
        - match: '\bNULL\b'
          scope: constant.language.c
        - match: '\b0[xX]\h[\h]*[uUlL]*\b'
          scope: constant.numeric.hex.c
        - match: '\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?[uUlLfF]*\b'
          scope: constant.numeric.c
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.c
        - match: '[-+*/%=<>!&|^~?:]+'
          scope: keyword.operator.c
      comments:
        - match: '/\*'
          scope: punctuation.definition.comment.c
          push: block_comment
        - match: '//'
          scope: punctuation.definition.comment.c
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-slash.c
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.c
        - match: '\*/'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.c
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.c
          push: char_literal
      # Only reached right after `#include`, not as a general top-level pattern — a
      # bare `<...>` lookahead in `main`/`strings` would also fire on comparison chains
      # and any other `<...>` shape, not just headers.
      include_line:
        - match: '<[^<>\n]*>'
          scope: string.quoted.other.lt-gt.c
          pop: true
        - match: '"'
          scope: punctuation.definition.string.begin.c
          push: double_string
        - match: '$'
          pop: true
      double_string:
        - meta_scope: string.quoted.double.c
        - match: '\\.'
          scope: constant.character.escape.c
        - match: '"'
          scope: punctuation.definition.string.end.c
          pop: true
        - match: '$'
          pop: true
      char_literal:
        - meta_scope: string.quoted.single.c
        - match: '\\.'
          scope: constant.character.escape.c
        - match: "'"
          scope: punctuation.definition.string.end.c
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - C++

    static let cpp = #"""
    %YAML 1.2
    ---
    name: C++
    scope: source.c++
    file_extensions: [cpp, cc, cxx, hpp, hh, "h++", "c++", inl, ipp, tpp]
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '^\s*#\s*include\b'
          scope: keyword.control.import.c++
          push: include_line
        - match: '^\s*#\s*(?:define|ifdef|ifndef|if|else|elif|endif|undef|pragma|error|line)\b'
          scope: keyword.control.import.c++
        - match: '\b(?:if|else|for|while|do|switch|case|default|break|continue|return|goto|sizeof|try|catch|throw)\b'
          scope: keyword.control.c++
        - match: '\b(?:class|struct|union|enum|namespace|template|typename|using|public|private|protected|virtual|override|final|friend|operator|explicit|mutable|constexpr|consteval|constinit|noexcept)\b'
          scope: storage.modifier.c++
        - match: '\b(?:typedef|auto|register|static|extern|const|volatile|inline)\b'
          scope: storage.modifier.c++
        - match: '\b(?:void|char|short|int|long|float|double|signed|unsigned|bool|wchar_t|char8_t|char16_t|char32_t)\b'
          scope: storage.type.primitive.c++
        - match: '\b(?:new|delete|this|nullptr|true|false)\b'
          scope: constant.language.c++
        - match: '\b(?:static_cast|dynamic_cast|const_cast|reinterpret_cast)\b(?=\s*<)'
          scope: keyword.operator.cast.c++
        - match: '\bstd::{{ident}}'
          scope: support.class.std.c++
        - match: '\b0[xX]\h[\h]*[uUlL]*\b'
          scope: constant.numeric.hex.c++
        - match: '\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?[uUlLfF]*\b'
          scope: constant.numeric.c++
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.c++
        - match: '[-+*/%=<>!&|^~?:]+'
          scope: keyword.operator.c++
      comments:
        - match: '/\*'
          scope: punctuation.definition.comment.c++
          push: block_comment
        - match: '//'
          scope: punctuation.definition.comment.c++
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-slash.c++
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.c++
        - match: '\*/'
          pop: true
      strings:
        - match: 'R"(\w*)\('
          scope: punctuation.definition.string.begin.c++
          push: raw_string
        - match: '"'
          scope: punctuation.definition.string.begin.c++
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.c++
          push: char_literal
      # Only reached right after `#include`, not as a general top-level pattern — a
      # bare `<...>` lookahead in `main`/`strings` would also fire on template syntax
      # like `map<string, int>` or `static_cast<int>(x)`, not just headers.
      include_line:
        - match: '<[^<>\n]*>'
          scope: string.quoted.other.lt-gt.c++
          pop: true
        - match: '"'
          scope: punctuation.definition.string.begin.c++
          push: double_string
        - match: '$'
          pop: true
      raw_string:
        - meta_scope: string.quoted.double.raw.c++
        - match: '\)\w*"'
          scope: punctuation.definition.string.end.c++
          pop: true
      double_string:
        - meta_scope: string.quoted.double.c++
        - match: '\\.'
          scope: constant.character.escape.c++
        - match: '"'
          scope: punctuation.definition.string.end.c++
          pop: true
        - match: '$'
          pop: true
      char_literal:
        - meta_scope: string.quoted.single.c++
        - match: '\\.'
          scope: constant.character.escape.c++
        - match: "'"
          scope: punctuation.definition.string.end.c++
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - C#

    static let csharp = #"""
    %YAML 1.2
    ---
    name: C#
    scope: source.cs
    file_extensions: [cs]
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:if|else|for|foreach|while|do|switch|case|default|break|continue|return|goto|try|catch|finally|throw|yield)\b'
          scope: keyword.control.cs
        - match: '\b(?:namespace|using|class|struct|interface|enum|record|delegate|event)\b'
          scope: storage.type.cs
        - match: '\b(?:public|private|protected|internal|static|readonly|const|virtual|override|abstract|sealed|partial|async|unsafe|extern|volatile|ref|out|in|params|this|base)\b'
          scope: storage.modifier.cs
        - match: '\b(?:void|bool|byte|sbyte|char|decimal|double|float|int|uint|long|ulong|object|short|ushort|string|var|dynamic)\b'
          scope: storage.type.primitive.cs
        - match: '\b(?:true|false|null|default)\b'
          scope: constant.language.cs
        - match: '@{{ident}}(?:\.{{ident}})*'
          scope: storage.modifier.attribute.cs
        - match: '\b(?:new|is|as|typeof|nameof|await)\b'
          scope: keyword.other.cs
        - match: '\bget\b|\bset\b|\bvalue\b'
          scope: keyword.other.property.cs
        - match: '\b0[xX]\h[\h_]*[uUlL]*\b'
          scope: constant.numeric.hex.cs
        - match: '\b\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?[uUlLfFdDmM]?\b'
          scope: constant.numeric.cs
        - match: '\b([A-Z]{{ident}})\b'
          scope: entity.name.type.cs
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.cs
        - match: '[-+*/%=<>!&|^~?:]+'
          scope: keyword.operator.cs
      comments:
        - match: '///'
          scope: punctuation.definition.comment.cs
          push: doc_comment
        - match: '/\*'
          scope: punctuation.definition.comment.cs
          push: block_comment
        - match: '//'
          scope: punctuation.definition.comment.cs
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-slash.cs
        - match: '$'
          pop: true
      doc_comment:
        - meta_scope: comment.line.documentation.cs
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.cs
        - match: '\*/'
          pop: true
      strings:
        - match: '\$@"|@\$"'
          scope: punctuation.definition.string.begin.cs
          push: verbatim_string
        - match: '@"'
          scope: punctuation.definition.string.begin.cs
          push: verbatim_string
        - match: '\$"'
          scope: punctuation.definition.string.begin.cs
          push: interpolated_string
        - match: '"'
          scope: punctuation.definition.string.begin.cs
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.cs
          push: char_literal
      double_string:
        - meta_scope: string.quoted.double.cs
        - match: '\\.'
          scope: constant.character.escape.cs
        - match: '"'
          scope: punctuation.definition.string.end.cs
          pop: true
        - match: '$'
          pop: true
      interpolated_string:
        - meta_scope: string.quoted.double.interpolated.cs
        - match: '\{\{|\}\}'
          scope: constant.character.escape.cs
        - match: '\{'
          scope: punctuation.section.interpolation.begin.cs
          push: interpolation
        - match: '\\.'
          scope: constant.character.escape.cs
        - match: '"'
          scope: punctuation.definition.string.end.cs
          pop: true
        - match: '$'
          pop: true
      interpolation:
        - meta_scope: meta.interpolation.cs
        - match: '\}'
          scope: punctuation.section.interpolation.end.cs
          pop: true
        - include: main
      verbatim_string:
        - meta_scope: string.quoted.double.verbatim.cs
        - match: '""'
          scope: constant.character.escape.cs
        - match: '"'
          scope: punctuation.definition.string.end.cs
          pop: true
      char_literal:
        - meta_scope: string.quoted.single.cs
        - match: '\\.'
          scope: constant.character.escape.cs
        - match: "'"
          scope: punctuation.definition.string.end.cs
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Objective-C

    static let objectivec = #"""
    %YAML 1.2
    ---
    name: Objective-C
    scope: source.objc
    file_extensions: [m, mm]
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '^\s*#\s*(?:import|include|define|ifdef|ifndef|if|else|elif|endif|undef|pragma|error)\b'
          scope: keyword.control.import.objc
        - match: '@(?:interface|implementation|end|protocol|property|synthesize|dynamic|class|selector|encode|import|autoreleasepool|try|catch|finally|throw|synchronized|optional|required)\b'
          scope: keyword.other.directive.objc
        - match: '\b(?:if|else|for|while|do|switch|case|default|break|continue|return|goto|sizeof)\b'
          scope: keyword.control.objc
        - match: '\b(?:typedef|struct|union|enum|static|extern|const|volatile|inline|nonatomic|atomic|strong|weak|copy|assign|readonly|readwrite|nullable|nonnull|IBOutlet|IBAction)\b'
          scope: storage.modifier.objc
        - match: '\b(?:void|char|short|int|long|float|double|signed|unsigned|BOOL|id|instancetype|SEL|IMP|Class)\b'
          scope: storage.type.primitive.objc
        - match: '\b(?:YES|NO|nil|Nil|NULL|self|super)\b'
          scope: constant.language.objc
        - match: '\b0[xX]\h[\h]*\b'
          scope: constant.numeric.hex.objc
        - match: '\b\d+(?:\.\d+)?\b'
          scope: constant.numeric.objc
        - match: '[\[\]]'
          scope: punctuation.section.message.objc
        - match: '[-+*/%=<>!&|^~?:]+'
          scope: keyword.operator.objc
      comments:
        - match: '/\*'
          scope: punctuation.definition.comment.objc
          push: block_comment
        - match: '//'
          scope: punctuation.definition.comment.objc
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-slash.objc
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.objc
        - match: '\*/'
          pop: true
      strings:
        - match: '@"'
          scope: punctuation.definition.string.begin.objc
          push: nsstring
        - match: '"'
          scope: punctuation.definition.string.begin.objc
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.objc
          push: char_literal
      nsstring:
        - meta_scope: string.quoted.double.objc
        - match: '\\.'
          scope: constant.character.escape.objc
        - match: '"'
          scope: punctuation.definition.string.end.objc
          pop: true
      double_string:
        - meta_scope: string.quoted.double.objc
        - match: '\\.'
          scope: constant.character.escape.objc
        - match: '"'
          scope: punctuation.definition.string.end.objc
          pop: true
        - match: '$'
          pop: true
      char_literal:
        - meta_scope: string.quoted.single.objc
        - match: '\\.'
          scope: constant.character.escape.objc
        - match: "'"
          scope: punctuation.definition.string.end.objc
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Rust

    static let rust = #"""
    %YAML 1.2
    ---
    name: Rust
    scope: source.rust
    file_extensions: [rs]
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:if|else|match|while|loop|for|in|break|continue|return)\b'
          scope: keyword.control.rust
        - match: '\b(?:fn|let|mut|const|static|struct|enum|impl|trait|mod|use|crate|pub|self|Self|super|where|as|dyn|move|ref|unsafe|async|await|type|extern)\b'
          scope: storage.type.rust
        - match: '\b(?:i8|i16|i32|i64|i128|isize|u8|u16|u32|u64|u128|usize|f32|f64|bool|char|str)\b'
          scope: storage.type.primitive.rust
        - match: '\b(?:true|false|None|Some|Ok|Err)\b'
          scope: constant.language.rust
        - match: '#!?\[[^\]]*\]'
          scope: storage.modifier.attribute.rust
        - match: "'[A-Za-z_][A-Za-z0-9_]*\\b(?!')"
          scope: storage.modifier.lifetime.rust
        - match: '\b({{ident}})!(?=[\s(\[{])'
          scope: support.function.macro.rust
        - match: '\b0[xX]\h[\h_]*\b'
          scope: constant.numeric.hex.rust
        - match: '\b0[bB][01][01_]*\b'
          scope: constant.numeric.binary.rust
        - match: '\b\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?(?:[iu](?:8|16|32|64|128|size)|f(?:32|64))?\b'
          scope: constant.numeric.rust
        - match: '\b([A-Z]{{ident}})\b'
          scope: entity.name.type.rust
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.rust
        - match: '->|::|[-+*/%=<>!&|^~?:]+'
          scope: keyword.operator.rust
      comments:
        - match: '///|//!'
          scope: punctuation.definition.comment.rust
          push: doc_comment
        - match: '/\*'
          scope: punctuation.definition.comment.rust
          push: block_comment
        - match: '//'
          scope: punctuation.definition.comment.rust
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-slash.rust
        - match: '$'
          pop: true
      doc_comment:
        - meta_scope: comment.line.documentation.rust
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.rust
        - match: '\*/'
          pop: true
      strings:
        - match: 'r#*"'
          scope: punctuation.definition.string.begin.rust
          push: raw_string
        - match: '"'
          scope: punctuation.definition.string.begin.rust
          push: double_string
        - match: "b'"
          scope: punctuation.definition.string.begin.rust
          push: byte_char_literal
      raw_string:
        - meta_scope: string.quoted.double.raw.rust
        - match: '"#*'
          scope: punctuation.definition.string.end.rust
          pop: true
      double_string:
        - meta_scope: string.quoted.double.rust
        - match: '\\.'
          scope: constant.character.escape.rust
        - match: '"'
          scope: punctuation.definition.string.end.rust
          pop: true
        - match: '$'
          pop: true
      byte_char_literal:
        - meta_scope: string.quoted.single.rust
        - match: '\\.'
          scope: constant.character.escape.rust
        - match: "'"
          scope: punctuation.definition.string.end.rust
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - Go

    static let go = #"""
    %YAML 1.2
    ---
    name: Go
    scope: source.go
    file_extensions: [go]
    variables:
      ident: '[A-Za-z_][A-Za-z_0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:if|else|switch|case|default|for|range|break|continue|goto|fallthrough|return|select|go|defer)\b'
          scope: keyword.control.go
        - match: '\b(?:package|import|func|var|const|type|struct|interface|map|chan)\b'
          scope: storage.type.go
        - match: '\b(?:bool|string|int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|uintptr|byte|rune|float32|float64|complex64|complex128|error|any)\b'
          scope: storage.type.primitive.go
        - match: '\b(?:true|false|nil|iota)\b'
          scope: constant.language.go
        - match: ':='
          scope: keyword.operator.assignment.go
        - match: '\b0[xX]\h[\h_]*\b'
          scope: constant.numeric.hex.go
        - match: '\b\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?\b'
          scope: constant.numeric.go
        - match: '\b([A-Z]{{ident}})\b'
          scope: entity.name.type.go
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.go
        - match: '<-|[-+*/%=<>!&|^~?:]+'
          scope: keyword.operator.go
      comments:
        - match: '/\*'
          scope: punctuation.definition.comment.go
          push: block_comment
        - match: '//'
          scope: punctuation.definition.comment.go
          push: line_comment
      line_comment:
        - meta_scope: comment.line.double-slash.go
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.go
        - match: '\*/'
          pop: true
      strings:
        - match: '`'
          scope: punctuation.definition.string.begin.go
          push: raw_string
        - match: '"'
          scope: punctuation.definition.string.begin.go
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.go
          push: rune_literal
      raw_string:
        - meta_scope: string.quoted.raw.go
        - match: '`'
          scope: punctuation.definition.string.end.go
          pop: true
      double_string:
        - meta_scope: string.quoted.double.go
        - match: '\\.'
          scope: constant.character.escape.go
        - match: '"'
          scope: punctuation.definition.string.end.go
          pop: true
        - match: '$'
          pop: true
      rune_literal:
        - meta_scope: string.quoted.single.go
        - match: '\\.'
          scope: constant.character.escape.go
        - match: "'"
          scope: punctuation.definition.string.end.go
          pop: true
        - match: '$'
          pop: true
    """#
}

import Foundation

/// Web and markup grammars. See `BuiltInGrammars` for the raw-string convention.
public extension BuiltInGrammars {

    // MARK: - JavaScript

    static let javascript = #"""
    %YAML 1.2
    ---
    name: JavaScript
    scope: source.js
    file_extensions: [js, mjs, cjs, jsx]
    first_line_match: '^#!.*\bnode\b'
    variables:
      ident: '[A-Za-z_$][A-Za-z_$0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:class|function|extends)\b'
          scope: storage.type.js
        - match: '\b(?:const|let|var|static|get|set|async)\b'
          scope: storage.modifier.js
        - match: '\b(?:if|else|for|while|do|switch|case|default|break|continue|return|try|catch|finally|throw|await|yield|new|delete|in|of|instanceof|typeof|void)\b'
          scope: keyword.control.js
        - match: '\b(?:import|export|from|as)\b'
          scope: keyword.other.import.js
        - match: '\b(?:true|false|null|undefined|NaN|Infinity)\b'
          scope: constant.language.js
        - match: '\b(?:this|super|globalThis)\b'
          scope: variable.language.js
        - match: '\b(?:console|Math|JSON|Object|Array|String|Number|Boolean|Promise|Map|Set|Symbol|Date|RegExp|Error)\b'
          scope: support.class.js
        - match: '\b0[xX]\h[\h_]*n?\b'
          scope: constant.numeric.hex.js
        - match: '\b\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?n?\b'
          scope: constant.numeric.js
        - match: '\b([A-Z]{{ident}})\b'
          scope: entity.name.type.js
        - match: '\b({{ident}})(?=\s*\()'
          scope: variable.function.js
        - match: '=>'
          scope: storage.type.function.arrow.js
        - match: '[-+*/%=<>!&|^~?:]+'
          scope: keyword.operator.js
      comments:
        - match: '//'
          scope: punctuation.definition.comment.js
          push: line_comment
        - match: '/\*'
          scope: punctuation.definition.comment.js
          push: block_comment
      line_comment:
        - meta_scope: comment.line.double-slash.js
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.js
        - match: '\*/'
          pop: true
      strings:
        - match: '`'
          scope: punctuation.definition.string.begin.js
          push: template_string
        - match: '"'
          scope: punctuation.definition.string.begin.js
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.js
          push: single_string
      template_string:
        - meta_scope: string.quoted.template.js
        - match: '\$\{'
          scope: punctuation.section.interpolation.begin.js
          push: interpolation
        - match: '\\.'
          scope: constant.character.escape.js
        - match: '`'
          scope: punctuation.definition.string.end.js
          pop: true
      interpolation:
        - meta_scope: meta.interpolation.js
        - match: '\}'
          scope: punctuation.section.interpolation.end.js
          pop: true
        - include: main
      double_string:
        - meta_scope: string.quoted.double.js
        - match: '\\.'
          scope: constant.character.escape.js
        - match: '"'
          scope: punctuation.definition.string.end.js
          pop: true
        - match: '$'
          pop: true
      single_string:
        - meta_scope: string.quoted.single.js
        - match: '\\.'
          scope: constant.character.escape.js
        - match: "'"
          scope: punctuation.definition.string.end.js
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - TypeScript

    /// Listed before JavaScript so `.ts`/`.tsx` resolve here first.
    static let typescript = #"""
    %YAML 1.2
    ---
    name: TypeScript
    scope: source.ts
    file_extensions: [ts, tsx, mts, cts]
    variables:
      ident: '[A-Za-z_$][A-Za-z_$0-9]*'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:interface|type|enum|namespace|module|declare|abstract|implements)\b'
          scope: storage.type.ts
        - match: '\b(?:class|function|extends)\b'
          scope: storage.type.class.ts
        - match: '\b(?:public|private|protected|readonly|override|const|let|var|static|get|set|async)\b'
          scope: storage.modifier.ts
        - match: '\b(?:if|else|for|while|do|switch|case|default|break|continue|return|try|catch|finally|throw|await|yield|new|delete|in|of|instanceof|typeof|keyof|satisfies|asserts|is|void)\b'
          scope: keyword.control.ts
        - match: '\b(?:import|export|from|as)\b'
          scope: keyword.other.import.ts
        - match: '\b(?:string|number|boolean|any|unknown|never|object|symbol|bigint)\b'
          scope: support.type.primitive.ts
        - match: '\b(?:true|false|null|undefined)\b'
          scope: constant.language.ts
        - match: '\b(?:this|super)\b'
          scope: variable.language.ts
        - match: '@{{ident}}'
          scope: storage.modifier.decorator.ts
        - match: '\b0[xX]\h[\h_]*n?\b'
          scope: constant.numeric.hex.ts
        - match: '\b\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?n?\b'
          scope: constant.numeric.ts
        - match: '\b([A-Z]{{ident}})\b'
          scope: entity.name.type.ts
        - match: '\b({{ident}})(?=\s*[(<])'
          scope: variable.function.ts
        - match: '=>'
          scope: storage.type.function.arrow.ts
        - match: '[-+*/%=<>!&|^~?:]+'
          scope: keyword.operator.ts
      comments:
        - match: '//'
          scope: punctuation.definition.comment.ts
          push: line_comment
        - match: '/\*'
          scope: punctuation.definition.comment.ts
          push: block_comment
      line_comment:
        - meta_scope: comment.line.double-slash.ts
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.ts
        - match: '\*/'
          pop: true
      strings:
        - match: '`'
          scope: punctuation.definition.string.begin.ts
          push: template_string
        - match: '"'
          scope: punctuation.definition.string.begin.ts
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.ts
          push: single_string
      template_string:
        - meta_scope: string.quoted.template.ts
        - match: '\$\{'
          scope: punctuation.section.interpolation.begin.ts
          push: interpolation
        - match: '\\.'
          scope: constant.character.escape.ts
        - match: '`'
          scope: punctuation.definition.string.end.ts
          pop: true
      interpolation:
        - meta_scope: meta.interpolation.ts
        - match: '\}'
          scope: punctuation.section.interpolation.end.ts
          pop: true
        - include: main
      double_string:
        - meta_scope: string.quoted.double.ts
        - match: '\\.'
          scope: constant.character.escape.ts
        - match: '"'
          scope: punctuation.definition.string.end.ts
          pop: true
        - match: '$'
          pop: true
      single_string:
        - meta_scope: string.quoted.single.ts
        - match: '\\.'
          scope: constant.character.escape.ts
        - match: "'"
          scope: punctuation.definition.string.end.ts
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - CSS

    static let css = #"""
    %YAML 1.2
    ---
    name: CSS
    scope: source.css
    file_extensions: [css, scss, sass, less]
    contexts:
      main:
        - match: '/\*'
          scope: punctuation.definition.comment.css
          push: block_comment
        - match: '//'
          scope: punctuation.definition.comment.css
          push: line_comment
        - match: '@[A-Za-z-]+'
          scope: keyword.control.at-rule.css
        - match: '"'
          scope: punctuation.definition.string.begin.css
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.css
          push: single_string
        - match: '\$[A-Za-z_-][A-Za-z0-9_-]*'
          scope: variable.other.css
        - match: '--[A-Za-z_-][A-Za-z0-9_-]*'
          scope: variable.other.custom-property.css
        - match: '#\h{3,8}\b'
          scope: constant.other.color.css
        - match: '\.[A-Za-z_-][A-Za-z0-9_-]*'
          scope: entity.other.attribute-name.class.css
        - match: '#[A-Za-z_-][A-Za-z0-9_-]*'
          scope: entity.other.attribute-name.id.css
        - match: '::?[A-Za-z-]+'
          scope: entity.other.pseudo-class.css
        - match: '\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|vmin|vmax|pt|pc|cm|mm|in|deg|s|ms|fr|ch|ex)?\b'
          scope: constant.numeric.css
        - match: '\b(?:!important|inherit|initial|unset|revert|auto|none)\b'
          scope: constant.language.css
        - match: '\b([a-z-]+)(?=\s*:)'
          scope: support.type.property-name.css
        - match: '\b([A-Za-z-]+)(?=\s*\()'
          scope: support.function.css
        - match: '[{}();:,]'
          scope: punctuation.separator.css
      block_comment:
        - meta_scope: comment.block.css
        - match: '\*/'
          pop: true
      line_comment:
        - meta_scope: comment.line.double-slash.css
        - match: '$'
          pop: true
      double_string:
        - meta_scope: string.quoted.double.css
        - match: '\\.'
          scope: constant.character.escape.css
        - match: '"'
          scope: punctuation.definition.string.end.css
          pop: true
      single_string:
        - meta_scope: string.quoted.single.css
        - match: '\\.'
          scope: constant.character.escape.css
        - match: "'"
          scope: punctuation.definition.string.end.css
          pop: true
    """#

    // MARK: - Markdown

    static let markdown = #"""
    %YAML 1.2
    ---
    name: Markdown
    scope: text.html.markdown
    file_extensions: [md, markdown, mdown, mkd, mdx]
    contexts:
      main:
        - match: '^(#{1,6})\s+(.*)$'
          scope: markup.heading.markdown
          captures:
            1: punctuation.definition.heading.markdown
        - match: '^\s*(?:[-*+]|\d+\.)\s'
          scope: markup.list.markdown punctuation.definition.list_item.markdown
        - match: '^>\s?'
          scope: markup.quote.markdown punctuation.definition.blockquote.markdown
        - match: '```'
          scope: punctuation.definition.raw.markdown
          push: fenced_code
        - match: '`'
          scope: punctuation.definition.raw.markdown
          push: inline_code
        - match: '\*\*(?=\S)'
          scope: punctuation.definition.bold.markdown
          push: bold
        - match: '(?<!\w)_(?=\S)|\*(?=\S)'
          scope: punctuation.definition.italic.markdown
          push: italic
        - match: '(!?\[)([^\]]*)(\])(\()([^)]*)(\))'
          captures:
            1: punctuation.definition.link.markdown
            2: string.other.link.title.markdown
            3: punctuation.definition.link.markdown
            5: markup.underline.link.markdown
        - match: '^(?:---+|===+|\*\*\*+)\s*$'
          scope: meta.separator.markdown
      fenced_code:
        - meta_scope: markup.raw.block.markdown
        - match: '```'
          scope: punctuation.definition.raw.markdown
          pop: true
      inline_code:
        - meta_scope: markup.raw.inline.markdown
        - match: '`'
          scope: punctuation.definition.raw.markdown
          pop: true
      bold:
        - meta_scope: markup.bold.markdown
        - match: '\*\*'
          scope: punctuation.definition.bold.markdown
          pop: true
        - match: '$'
          pop: true
      italic:
        - meta_scope: markup.italic.markdown
        - match: '_|\*'
          scope: punctuation.definition.italic.markdown
          pop: true
        - match: '$'
          pop: true
    """#
}

import Foundation

/// SQL and dynamic-scripting-language grammars. See `BuiltInGrammars` for the raw-string
/// convention.
public extension BuiltInGrammars {

    // MARK: - SQL

    static let sql = #"""
    %YAML 1.2
    ---
    name: SQL
    scope: source.sql
    file_extensions: [sql, ddl, dml]
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '(?i)\b(?:select|insert|update|delete|from|where|into|values|set|join|inner|left|right|full|outer|cross|on|group|by|order|having|union|all|distinct|as|and|or|not|null|is|in|exists|between|like|ilike|limit|offset|asc|desc|with|recursive|case|when|then|else|end|over|partition)\b'
          scope: keyword.control.sql
        - match: '(?i)\b(?:create|alter|drop|table|view|index|database|schema|sequence|trigger|procedure|function|primary|key|foreign|references|constraint|default|unique|check|cascade|column|add|modify|rename|if)\b'
          scope: storage.type.sql
        - match: '(?i)\b(?:begin|commit|rollback|transaction|grant|revoke|savepoint)\b'
          scope: keyword.other.sql
        - match: '(?i)\b(?:int|integer|bigint|smallint|tinyint|decimal|numeric|float|double|real|char|varchar|nvarchar|text|clob|blob|date|datetime|timestamp|time|boolean|bool|serial|uuid|json|jsonb)\b'
          scope: storage.type.primitive.sql
        - match: '(?i)\b(?:true|false)\b'
          scope: constant.language.sql
        - match: '\bNULL\b'
          scope: constant.language.null.sql
        - match: '\b\d+(?:\.\d+)?\b'
          scope: constant.numeric.sql
        - match: '\b([A-Za-z_][A-Za-z0-9_]*)(?=\s*\()'
          scope: support.function.sql
        - match: '[-+*/%=<>!]+'
          scope: keyword.operator.sql
        - match: ';'
          scope: punctuation.terminator.sql
      comments:
        - match: '--'
          scope: punctuation.definition.comment.sql
          push: line_comment
        - match: '/\*'
          scope: punctuation.definition.comment.sql
          push: block_comment
      line_comment:
        - meta_scope: comment.line.double-dash.sql
        - match: '$'
          pop: true
      block_comment:
        - meta_scope: comment.block.sql
        - match: '\*/'
          pop: true
      strings:
        - match: "'"
          scope: punctuation.definition.string.begin.sql
          push: single_string
        - match: '"'
          scope: punctuation.definition.string.begin.sql
          push: quoted_identifier
        - match: '`'
          scope: punctuation.definition.string.begin.sql
          push: backtick_identifier
      single_string:
        - meta_scope: string.quoted.single.sql
        - match: "''"
          scope: constant.character.escape.sql
        - match: "'"
          scope: punctuation.definition.string.end.sql
          pop: true
      quoted_identifier:
        - meta_scope: string.quoted.double.sql
        - match: '""'
          scope: constant.character.escape.sql
        - match: '"'
          scope: punctuation.definition.string.end.sql
          pop: true
      backtick_identifier:
        - meta_scope: string.quoted.other.backtick.sql
        - match: '`'
          scope: punctuation.definition.string.end.sql
          pop: true
    """#

    // MARK: - Perl

    static let perl = #"""
    %YAML 1.2
    ---
    name: Perl
    scope: source.perl
    file_extensions: [pl, pm, perl, plx, pod]
    first_line_match: '^#!.*\bperl\b'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:my|our|local|sub)\b'
          scope: storage.type.perl
        - match: '\b(?:if|elsif|else|unless|while|until|for|foreach|do|last|next|redo|return)\b'
          scope: keyword.control.perl
        - match: '\b(?:use|no|package|require|BEGIN|END)\b'
          scope: keyword.other.perl
        - match: '\b(?:undef|shift|push|pop|splice|print|printf|sprintf|defined|ref|bless|die|warn|wantarray|keys|values|each|exists|delete|scalar|map|grep|sort|join|split|length|substr|index|chomp|chop)\b'
          scope: support.function.builtin.perl
        - match: '[$@%][A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*'
          scope: variable.other.perl
        - match: '[$@%]\{'
          scope: variable.other.perl
        - match: '=>'
          scope: punctuation.separator.key-value.perl
        - match: '\b\d+(?:\.\d+)?\b'
          scope: constant.numeric.perl
        - match: '[-+*/%=<>!&|^~?:.]+'
          scope: keyword.operator.perl
      comments:
        - match: '^=(?:pod|head1|head2|head3|item|over|back|begin|end|for|encoding)\b'
          scope: comment.block.documentation.perl
          push: pod
        - match: '#'
          scope: punctuation.definition.comment.perl
          push: line_comment
      pod:
        - meta_scope: comment.block.documentation.perl
        - match: '^=cut\b'
          pop: true
      line_comment:
        - meta_scope: comment.line.number-sign.perl
        - match: '$'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.perl
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.perl
          push: single_string
        - match: '`'
          scope: punctuation.definition.string.begin.perl
          push: backtick_string
        - match: '\bqw[([{/]'
          scope: punctuation.definition.string.begin.perl
          push: qw_list
      double_string:
        - meta_scope: string.quoted.double.perl
        - match: '\\.'
          scope: constant.character.escape.perl
        - match: '[$@]\{?[A-Za-z_][A-Za-z0-9_]*\}?'
          scope: variable.other.perl
        - match: '"'
          scope: punctuation.definition.string.end.perl
          pop: true
        - match: '$'
          pop: true
      single_string:
        - meta_scope: string.quoted.single.perl
        - match: '\\.'
          scope: constant.character.escape.perl
        - match: "'"
          scope: punctuation.definition.string.end.perl
          pop: true
        - match: '$'
          pop: true
      backtick_string:
        - meta_scope: string.interpolated.backtick.perl
        - match: '\\.'
          scope: constant.character.escape.perl
        - match: '`'
          scope: punctuation.definition.string.end.perl
          pop: true
      qw_list:
        - meta_scope: string.unquoted.qw.perl
        - match: '[)\]}/]'
          scope: punctuation.definition.string.end.perl
          pop: true
        - match: '$'
          pop: true
    """#

    // MARK: - PHP

    static let php = #"""
    %YAML 1.2
    ---
    name: PHP
    scope: source.php
    file_extensions: [php, phtml, php3, php4, php5, php7, inc]
    first_line_match: '^#!.*\bphp\b'
    contexts:
      main:
        - match: '<\?php\b|<\?='
          scope: punctuation.section.embedded.begin.php
        - match: '\?>'
          scope: punctuation.section.embedded.end.php
        - include: comments
        - include: strings
        - match: '\b(?:function|fn|class|interface|trait|enum|extends|implements|abstract|final|readonly)\b'
          scope: storage.type.php
        - match: '\b(?:public|private|protected|static|const|var|global)\b'
          scope: storage.modifier.php
        - match: '\b(?:if|elseif|else|endif|while|endwhile|do|for|endfor|foreach|endforeach|as|switch|endswitch|case|default|break|continue|return|match)\b'
          scope: keyword.control.php
        - match: '\b(?:namespace|use|require|require_once|include|include_once|new|clone|instanceof|try|catch|finally|throw|yield|list|array|isset|unset|empty|echo|print)\b'
          scope: keyword.other.php
        - match: '\b(?:true|false|null|self|parent|this)\b'
          scope: constant.language.php
        - match: '\$[A-Za-z_][A-Za-z0-9_]*'
          scope: variable.other.php
        - match: '\b0[xX]\h[\h]*\b'
          scope: constant.numeric.hex.php
        - match: '\b\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\b'
          scope: constant.numeric.php
        - match: '->|::|[-+*/%=<>!&|^~?:.]+'
          scope: keyword.operator.php
      comments:
        - match: '//|#(?!\[)'
          scope: punctuation.definition.comment.php
          push: line_comment
        - match: '/\*'
          scope: punctuation.definition.comment.php
          push: block_comment
      line_comment:
        - meta_scope: comment.line.php
        - match: '(?=\?>)|$'
          pop: true
      block_comment:
        - meta_scope: comment.block.php
        - match: '\*/'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.php
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.php
          push: single_string
      double_string:
        - meta_scope: string.quoted.double.php
        - match: '\\.'
          scope: constant.character.escape.php
        - match: '\$[A-Za-z_][A-Za-z0-9_]*(?:->[A-Za-z_][A-Za-z0-9_]*)?'
          scope: variable.other.php
        - match: '\{\$'
          scope: punctuation.section.interpolation.begin.php
          push: interpolation
        - match: '"'
          scope: punctuation.definition.string.end.php
          pop: true
      interpolation:
        - meta_scope: meta.interpolation.php
        - match: '\}'
          scope: punctuation.section.interpolation.end.php
          pop: true
        - include: main
      single_string:
        - meta_scope: string.quoted.single.php
        - match: '\\.'
          scope: constant.character.escape.php
        - match: "'"
          scope: punctuation.definition.string.end.php
          pop: true
    """#

    // MARK: - Ruby

    static let ruby = #"""
    %YAML 1.2
    ---
    name: Ruby
    scope: source.ruby
    file_extensions: [rb, rake, gemspec, ru, rbw, podspec]
    first_line_match: '^#!.*\bruby\b'
    contexts:
      main:
        - include: comments
        - include: strings
        - match: '\b(?:def|class|module|end)\b'
          scope: storage.type.ruby
        - match: '\b(?:if|elsif|else|unless|while|until|for|in|do|begin|rescue|ensure|raise|return|yield|break|next|redo|retry|case|when|then)\b'
          scope: keyword.control.ruby
        - match: '\b(?:require|require_relative|include|extend|attr_accessor|attr_reader|attr_writer|private|public|protected|module_function|lambda|proc|new)\b'
          scope: support.function.builtin.ruby
        - match: '\b(?:true|false|nil|self|__method__|__FILE__|__LINE__)\b'
          scope: constant.language.ruby
        - match: ':[A-Za-z_][A-Za-z0-9_]*[?!=]?'
          scope: constant.other.symbol.ruby
        - match: '@@[A-Za-z_][A-Za-z0-9_]*'
          scope: variable.other.readwrite.class.ruby
        - match: '@[A-Za-z_][A-Za-z0-9_]*'
          scope: variable.other.readwrite.instance.ruby
        - match: '\$[A-Za-z_][A-Za-z0-9_]*'
          scope: variable.other.readwrite.global.ruby
        - match: '\b\d+(?:\.\d+)?\b'
          scope: constant.numeric.ruby
        - match: '=>|->|[-+*/%=<>!&|^~?:.]+'
          scope: keyword.operator.ruby
      comments:
        - match: '^=begin\b'
          scope: comment.block.documentation.ruby
          push: block_pod
        - match: '#'
          scope: punctuation.definition.comment.ruby
          push: line_comment
      block_pod:
        - meta_scope: comment.block.documentation.ruby
        - match: '^=end\b'
          pop: true
      line_comment:
        - meta_scope: comment.line.number-sign.ruby
        - match: '$'
          pop: true
      strings:
        - match: '"'
          scope: punctuation.definition.string.begin.ruby
          push: double_string
        - match: "'"
          scope: punctuation.definition.string.begin.ruby
          push: single_string
        - match: '%w[([{/]'
          scope: punctuation.definition.string.begin.ruby
          push: word_array
      double_string:
        - meta_scope: string.quoted.double.ruby
        - match: '\\.'
          scope: constant.character.escape.ruby
        - match: '#\{'
          scope: punctuation.section.interpolation.begin.ruby
          push: interpolation
        - match: '"'
          scope: punctuation.definition.string.end.ruby
          pop: true
      interpolation:
        - meta_scope: meta.interpolation.ruby
        - match: '\}'
          scope: punctuation.section.interpolation.end.ruby
          pop: true
        - include: main
      single_string:
        - meta_scope: string.quoted.single.ruby
        - match: '\\.'
          scope: constant.character.escape.ruby
        - match: "'"
          scope: punctuation.definition.string.end.ruby
          pop: true
      word_array:
        - meta_scope: string.unquoted.word-array.ruby
        - match: '[)\]}/]'
          scope: punctuation.definition.string.end.ruby
          pop: true
        - match: '$'
          pop: true
    """#
}

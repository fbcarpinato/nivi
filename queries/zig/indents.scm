; Nivi indentation captures:
;   @indent.begin - descendants are indented one level
;   @indent.end   - a line beginning with this token is dedented one level

[
  (block)
  (struct_declaration)
  (enum_declaration)
  (union_declaration)
  (opaque_declaration)
  (initializer_list)
  (switch_expression)
] @indent.begin

[
  "}"
  "]"
  ")"
] @indent.end

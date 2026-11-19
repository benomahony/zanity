// tree-sitter, built as one translation unit with a way to skip ts_query_new's pattern analysis.
//
// ts_query_new parses a query's patterns, which is fast, then analyses them against the
// grammar's parse table, which takes seconds for a large grammar such as Swift's. The analysis
// only sets three flags on each step, one on each pattern and a sorted list of symbols, all
// determined by the query and the grammar. zanity records them when it is built and gives them
// back when it compiles the query, so ts_query_new runs as written but the analysis is replaced.
//
// The macro below renames the analysis where query.c defines it, to zanity_full_analysis, and
// sends the one call in ts_query_new to zanity_analysis_hook: the definition's first argument
// starts with `TSQuery`, the call's with `self`.

#include "tree_sitter/api.h"

#define ts_query__analyze_patterns(first, rest) ZANITY_PICK_##first, rest)
#define ZANITY_PICK_TSQuery zanity_full_analysis(TSQuery
#define ZANITY_PICK_self zanity_analysis_hook(self

static bool zanity_analysis_hook(TSQuery *self, unsigned *error_offset);

#include "lib.c"

#undef ts_query__analyze_patterns

#define ZANITY_ANALYSIS_MAGIC 0x31415a5au
#define ZANITY_STEP_CONTAINS_CAPTURES 1u
#define ZANITY_STEP_PARENT_GUARANTEED 2u
#define ZANITY_STEP_ROOT_GUARANTEED 4u

static _Thread_local const uint8_t *zanity_replay = NULL;
static _Thread_local uint32_t zanity_replay_len = 0;

static void zanity_put_u32(uint8_t *out, uint32_t at, uint32_t value) {
  out[at] = (uint8_t)value;
  out[at + 1] = (uint8_t)(value >> 8);
  out[at + 2] = (uint8_t)(value >> 16);
  out[at + 3] = (uint8_t)(value >> 24);
}

static uint32_t zanity_get_u32(const uint8_t *in, uint32_t at) {
  return (uint32_t)in[at] | (uint32_t)in[at + 1] << 8 | (uint32_t)in[at + 2] << 16 | (uint32_t)in[at + 3] << 24;
}

static uint32_t zanity_analysis_size(uint32_t steps, uint32_t patterns, uint32_t symbols) {
  return 16 + steps + patterns + 2 * symbols;
}

// The bytes recording what the analysis set on `self`: a header of the magic number and the
// step, pattern and symbol counts, then one byte of flags per step, one byte per pattern, and
// each repetition symbol as two bytes, all little-endian. Returns the size, and writes only when
// `out` has room for it.
uint32_t zanity_query_analysis(const TSQuery *self, uint8_t *out, uint32_t capacity) {
  uint32_t steps = self->steps.size;
  uint32_t patterns = self->patterns.size;
  uint32_t symbols = self->repeat_symbols_with_rootless_patterns.size;
  uint32_t size = zanity_analysis_size(steps, patterns, symbols);
  if (!out || capacity < size) return size;
  zanity_put_u32(out, 0, ZANITY_ANALYSIS_MAGIC);
  zanity_put_u32(out, 4, steps);
  zanity_put_u32(out, 8, patterns);
  zanity_put_u32(out, 12, symbols);
  uint32_t at = 16;
  for (uint32_t i = 0; i < steps; i++) {
    const QueryStep *step = array_get(&self->steps, i);
    out[at++] = (uint8_t)(
      (step->contains_captures ? ZANITY_STEP_CONTAINS_CAPTURES : 0) |
      (step->parent_pattern_guaranteed ? ZANITY_STEP_PARENT_GUARANTEED : 0) |
      (step->root_pattern_guaranteed ? ZANITY_STEP_ROOT_GUARANTEED : 0)
    );
  }
  for (uint32_t i = 0; i < patterns; i++) out[at++] = array_get(&self->patterns, i)->is_non_local ? 1 : 0;
  for (uint32_t i = 0; i < symbols; i++) {
    TSSymbol symbol = *array_get(&self->repeat_symbols_with_rootless_patterns, i);
    out[at++] = (uint8_t)symbol;
    out[at++] = (uint8_t)(symbol >> 8);
  }
  return size;
}

// Sets what the analysis would have from recorded bytes, refusing bytes recorded for another
// query: their counts must match the steps and patterns just parsed.
static bool zanity_apply_analysis(TSQuery *self, const uint8_t *in, uint32_t len) {
  if (len < 16 || zanity_get_u32(in, 0) != ZANITY_ANALYSIS_MAGIC) return false;
  uint32_t steps = zanity_get_u32(in, 4);
  uint32_t patterns = zanity_get_u32(in, 8);
  uint32_t symbols = zanity_get_u32(in, 12);
  if (steps != self->steps.size || patterns != self->patterns.size) return false;
  if (len != zanity_analysis_size(steps, patterns, symbols)) return false;
  uint32_t at = 16;
  for (uint32_t i = 0; i < steps; i++) {
    QueryStep *step = array_get(&self->steps, i);
    uint8_t flags = in[at++];
    step->contains_captures = (flags & ZANITY_STEP_CONTAINS_CAPTURES) != 0;
    step->parent_pattern_guaranteed = (flags & ZANITY_STEP_PARENT_GUARANTEED) != 0;
    step->root_pattern_guaranteed = (flags & ZANITY_STEP_ROOT_GUARANTEED) != 0;
  }
  for (uint32_t i = 0; i < patterns; i++) array_get(&self->patterns, i)->is_non_local = in[at++] != 0;
  array_clear(&self->repeat_symbols_with_rootless_patterns);
  for (uint32_t i = 0; i < symbols; i++) {
    TSSymbol symbol = (TSSymbol)(in[at] | in[at + 1] << 8);
    at += 2;
    array_push(&self->repeat_symbols_with_rootless_patterns, symbol);
  }
  return at == len;
}

static bool zanity_analysis_hook(TSQuery *self, unsigned *error_offset) {
  if (!zanity_replay) return zanity_full_analysis(self, error_offset);
  *error_offset = 0;
  return zanity_apply_analysis(self, zanity_replay, zanity_replay_len);
}

// ts_query_new with the analysis replaced by bytes zanity_query_analysis() recorded for the same
// query and grammar. Bytes for another query fail it with TSQueryErrorStructure at offset 0.
TSQuery *zanity_query_new_analysed(
  const TSLanguage *language,
  const char *source,
  uint32_t source_len,
  const uint8_t *analysis,
  uint32_t analysis_len,
  uint32_t *error_offset,
  TSQueryError *error_type
) {
  zanity_replay = analysis;
  zanity_replay_len = analysis_len;
  TSQuery *query = ts_query_new(language, source, source_len, error_offset, error_type);
  zanity_replay = NULL;
  zanity_replay_len = 0;
  return query;
}

static bool zanity_symbols_equal(const SymbolTable *a, const SymbolTable *b) {
  if (a->characters.size != b->characters.size || a->slices.size != b->slices.size) return false;
  if (a->characters.size && memcmp(a->characters.contents, b->characters.contents, a->characters.size)) return false;
  for (uint32_t i = 0; i < a->slices.size; i++) {
    const Slice *x = array_get(&a->slices, i), *y = array_get(&b->slices, i);
    if (x->offset != y->offset || x->length != y->length) return false;
  }
  return true;
}

static bool zanity_steps_equal(const QueryStep *x, const QueryStep *y) {
  for (unsigned k = 0; k < MAX_STEP_CAPTURE_COUNT; k++) if (x->capture_ids[k] != y->capture_ids[k]) return false;
  return x->symbol == y->symbol && x->supertype_symbol == y->supertype_symbol && x->field == y->field &&
    x->depth == y->depth && x->alternative_index == y->alternative_index &&
    x->negated_field_list_id == y->negated_field_list_id && x->is_named == y->is_named &&
    x->is_immediate == y->is_immediate && x->is_last_child == y->is_last_child &&
    x->is_pass_through == y->is_pass_through && x->is_dead_end == y->is_dead_end &&
    x->alternative_is_immediate == y->alternative_is_immediate && x->contains_captures == y->contains_captures &&
    x->root_pattern_guaranteed == y->root_pattern_guaranteed &&
    x->parent_pattern_guaranteed == y->parent_pattern_guaranteed && x->is_missing == y->is_missing;
}

// Whether two queries hold the same state, field by field, so that a query compiled from
// recorded analysis can be checked against one ts_query_new analysed itself.
bool zanity_query_equal(const TSQuery *a, const TSQuery *b) {
  if (a->language != b->language || a->wildcard_root_pattern_count != b->wildcard_root_pattern_count) return false;
  if (!zanity_symbols_equal(&a->captures, &b->captures) || !zanity_symbols_equal(&a->predicate_values, &b->predicate_values)) return false;
  if (a->capture_quantifiers.size != b->capture_quantifiers.size) return false;
  for (uint32_t i = 0; i < a->capture_quantifiers.size; i++) {
    const CaptureQuantifiers *x = array_get(&a->capture_quantifiers, i), *y = array_get(&b->capture_quantifiers, i);
    if (x->size != y->size || (x->size && memcmp(x->contents, y->contents, x->size))) return false;
  }
  if (a->steps.size != b->steps.size) return false;
  for (uint32_t i = 0; i < a->steps.size; i++) if (!zanity_steps_equal(array_get(&a->steps, i), array_get(&b->steps, i))) return false;
  if (a->pattern_map.size != b->pattern_map.size) return false;
  for (uint32_t i = 0; i < a->pattern_map.size; i++) {
    const PatternEntry *x = array_get(&a->pattern_map, i), *y = array_get(&b->pattern_map, i);
    if (x->step_index != y->step_index || x->pattern_index != y->pattern_index || x->is_rooted != y->is_rooted) return false;
  }
  if (a->predicate_steps.size != b->predicate_steps.size) return false;
  for (uint32_t i = 0; i < a->predicate_steps.size; i++) {
    const TSQueryPredicateStep *x = array_get(&a->predicate_steps, i), *y = array_get(&b->predicate_steps, i);
    if (x->type != y->type || x->value_id != y->value_id) return false;
  }
  if (a->patterns.size != b->patterns.size) return false;
  for (uint32_t i = 0; i < a->patterns.size; i++) {
    const QueryPattern *x = array_get(&a->patterns, i), *y = array_get(&b->patterns, i);
    if (x->steps.offset != y->steps.offset || x->steps.length != y->steps.length ||
        x->predicate_steps.offset != y->predicate_steps.offset || x->predicate_steps.length != y->predicate_steps.length ||
        x->start_byte != y->start_byte || x->end_byte != y->end_byte || x->is_non_local != y->is_non_local) return false;
  }
  if (a->step_offsets.size != b->step_offsets.size) return false;
  for (uint32_t i = 0; i < a->step_offsets.size; i++) {
    const StepOffset *x = array_get(&a->step_offsets, i), *y = array_get(&b->step_offsets, i);
    if (x->byte_offset != y->byte_offset || x->step_index != y->step_index) return false;
  }
  if (a->negated_fields.size != b->negated_fields.size) return false;
  if (a->negated_fields.size && memcmp(a->negated_fields.contents, b->negated_fields.contents, a->negated_fields.size * sizeof(TSFieldId))) return false;
  if (a->repeat_symbols_with_rootless_patterns.size != b->repeat_symbols_with_rootless_patterns.size) return false;
  for (uint32_t i = 0; i < a->repeat_symbols_with_rootless_patterns.size; i++) {
    if (*array_get(&a->repeat_symbols_with_rootless_patterns, i) != *array_get(&b->repeat_symbols_with_rootless_patterns, i)) return false;
  }
  return true;
}

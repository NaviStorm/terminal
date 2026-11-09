#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct MTParser MTParser;
typedef struct {
    const uint8_t *bytes;
    size_t len;
    uint32_t fg, bg;
    bool bold, underline, wide;
} MTPaint;

MTParser *mt_new(uint16_t rows, uint16_t cols, uint16_t history);
void mt_parser_counts(uint64_t *created, uint64_t *freed);
void mt_free(MTParser *);
void mt_feed(MTParser *, const uint8_t *, size_t);
char *mt_take_replies(MTParser *);
char *mt_take_title(MTParser *);
bool mt_find(MTParser *, const char *query, int32_t start, bool reverse, int32_t *first, int32_t *last);
void mt_resize(MTParser *, uint16_t rows, uint16_t cols);
void mt_scroll(MTParser *, int32_t delta);
bool mt_application_cursor(MTParser *);
bool mt_bracketed_paste(MTParser *);
bool mt_mouse_enabled(MTParser *);
size_t mt_mouse_report(MTParser *, uint8_t button, bool release, bool motion,
                       uint8_t modifiers, uint16_t row, uint16_t col, uint8_t out[32]);
void mt_content_size(MTParser *, uint16_t *rows, uint16_t *cols);
bool mt_cursor(MTParser *, uint16_t *row, uint16_t *col);
// Les octets restent valides jusqu'à la prochaine mutation du parseur.
bool mt_cell(MTParser *, uint16_t row, uint16_t col, MTPaint *);
void mt_click_range(MTParser *, int32_t index, bool line, int32_t *first, int32_t *last);
char *mt_selection(MTParser *, uint16_t row, uint16_t col, uint16_t endRow, uint16_t endCol);
void mt_string_free(char *);

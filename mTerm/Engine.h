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

MTParser *mt_new(uint16_t rows, uint16_t cols);
void mt_free(MTParser *);
void mt_feed(MTParser *, const uint8_t *, size_t);
void mt_resize(MTParser *, uint16_t rows, uint16_t cols);
void mt_scroll(MTParser *, int32_t delta);
bool mt_application_cursor(MTParser *);
bool mt_bracketed_paste(MTParser *);
bool mt_cursor(MTParser *, uint16_t *row, uint16_t *col);
// Les octets restent valides jusqu'à la prochaine mutation du parseur.
bool mt_cell(MTParser *, uint16_t row, uint16_t col, MTPaint *);
char *mt_selection(MTParser *, uint16_t row, uint16_t col, uint16_t endRow, uint16_t endCol);
void mt_string_free(char *);

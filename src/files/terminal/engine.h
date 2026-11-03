#ifndef REDIWM_FILES_TERMINAL_ENGINE_H
#define REDIWM_FILES_TERMINAL_ENGINE_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "protocol.h"
typedef struct ft_terminal FT;
typedef struct {
    uint32_t chars[6];
    uint8_t fg[3], bg[3], width;
    uint16_t attrs;
} FT_Cell;
enum { FT_BOLD=1, FT_ITALIC=2, FT_UNDERLINE=4, FT_STRIKE=8, FT_REVERSE=16, FT_CONCEAL=32 };
FT *ft_new(int rows, int cols);
/* Optional allocator for the engine and libvterm, with max_align_t alignment.
 * Library allocation failure tears down the emulator and reports a failed
 * session instead of letting libvterm dereference NULL in the Files process. */
typedef struct {
    void *owner;
    void *(*alloc)(void *owner, size_t bytes);
    void (*free)(void *owner, void *pointer);
} FT_Allocator;
FT *ft_new_alloc(int rows, int cols, const FT_Allocator *allocator);
void ft_free(FT *t);
int ft_start(FT *t, const char *helper, const char *plugin, const char *directory, bool scope);
void ft_resize(FT *t, int rows, int cols);
void ft_feed(FT *t, const char *bytes, size_t len);
int ft_pty(const FT *t);
int ft_channel(const FT *t);
int ft_exit_fd(const FT *t);
bool ft_wants_write(const FT *t);
bool ft_wants_request(const FT *t);
void ft_io(FT *t, bool read_pty, bool write_pty, bool channel, bool exited);
bool ft_changed(FT *t);
bool ft_running(const FT *t);
bool ft_active(const FT *t);
bool ft_exited(const FT *t);
int ft_exit_status(const FT *t);
const char *ft_error(const FT *t);
void ft_close(FT *t, bool force);
int ft_follow(FT *t, const char *directory);
const struct ft_status *ft_status(const FT *t);
bool ft_pending(const FT *t);
void ft_palette(FT *t, int index, uint8_t r, uint8_t g, uint8_t b);
bool ft_cell(FT *t, int row, int col, FT_Cell *cell);
int64_t ft_line(const FT *t);
bool ft_cell_at(FT *t, int64_t line, int col, FT_Cell *cell);
bool ft_wrapped_at(FT *t, int64_t line);
bool ft_wrapped(FT *t, int row);
int ft_history(const FT *t);
size_t ft_history_bytes(const FT *t);
int ft_offset(const FT *t);
void ft_scroll(FT *t, int lines);
void ft_key(FT *t, uint32_t sym, const char *text, size_t len, int modifiers);
bool ft_paste(FT *t, const char *bytes, size_t len);
void ft_mouse(FT *t, int row, int col, int button, bool pressed, int modifiers);
int ft_mouse_mode(const FT *t);
void ft_focus(FT *t, bool focused);
bool ft_cursor(const FT *t, int *row, int *col, int *shape);
int ft_rows(const FT *t);
int ft_cols(const FT *t);
#ifdef FT_TEST
/* Noninstalled unit fixture access to queued encoder output. */
size_t ft_take_output(FT *t, char *bytes, size_t capacity);
#endif
#endif

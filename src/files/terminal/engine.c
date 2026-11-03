#define _GNU_SOURCE
#include "engine.h"
#include <vterm.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-keysyms.h>
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pty.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include "../../platform/child.h"

#if VTERM_VERSION_MAJOR != 0 || VTERM_VERSION_MINOR != 3 || VTERM_VERSION_PATCH < 3
#error Files requires libvterm 0.3.3 (0.3 ABI)
#endif

extern char **environ;
enum { HISTORY_LINES=4096, HISTORY_BYTES=8*1024*1024, OUTPUT_BYTES=1024*1024,
    READ_BUDGET=64*1024, GRID_MAX=512 };
struct line { VTermScreenCell *cells; int cols; bool wrapped; };
struct allocation {
    struct allocation *next, *previous;
    union { long double value; void *pointer; } alignment;
};
struct ft_terminal {
    FT_Allocator allocator;
    struct allocation *allocations;
    jmp_buf allocation_failure;
    VTerm *vt;
    VTermScreen *screen;
    VTermState *state;
    int master, channel, process;
    pid_t pid;
    bool exited, eof, changed, cursor_visible, reverse, alternate;
    int exit_status, rows, cols, mouse, cursor_shape;
    VTermPos cursor;
    struct line history[HISTORY_LINES];
    int first, count, offset;
    int64_t line;
    size_t history_bytes;
    char output[OUTPUT_BYTES];
    size_t out_start, out_len;
    struct ft_request request;
    bool request_queued;
    uint64_t serial;
    struct ft_status status;
    const char *error;
};

static int damage(VTermRect rect, void *user) { (void)rect; ((FT *)user)->changed=true; return 1; }
static int cursor(VTermPos pos, VTermPos old, int visible, void *user) {
    (void)old; FT *t=user; t->cursor=pos; t->cursor_visible=visible; t->changed=true; return 1;
}
static int property(VTermProp prop, VTermValue *val, void *user) {
    FT *t=user;
    switch (prop) {
    case VTERM_PROP_CURSORVISIBLE: t->cursor_visible=val->boolean; break;
    case VTERM_PROP_CURSORSHAPE: t->cursor_shape=val->number; break;
    case VTERM_PROP_REVERSE: t->reverse=val->boolean; break;
    case VTERM_PROP_ALTSCREEN: t->alternate=val->boolean; t->offset=0; break;
    case VTERM_PROP_MOUSE: t->mouse=val->number; break;
    default: break; /* Titles, OSC 7/8/52: no desktop side effects. */
    }
    t->changed=true; return 1;
}
static void drop_oldest(FT *t) {
    struct line *line=&t->history[t->first];
    t->history_bytes-=(size_t)line->cols*sizeof *line->cells;
    free(line->cells); *line=(struct line){0};
    t->first=(t->first+1)%HISTORY_LINES; t->count--;
}
static int pushline(int cols, const VTermScreenCell *cells, void *user) {
    FT *t=user;
    size_t bytes=(size_t)cols*sizeof *cells;
    if (bytes>HISTORY_BYTES) return 0;
    VTermScreenCell *copy=malloc(bytes);
    if (!copy) return 0; /* Output continues; old history remains valid. */
    memcpy(copy,cells,bytes);
    for (int col=0;col<cols;col++) copy[col].attrs.reverse^=t->reverse;
    while (t->count==HISTORY_LINES || t->history_bytes+bytes>HISTORY_BYTES) drop_oldest(t);
    const VTermLineInfo *next=t->rows>1 ? vterm_state_get_lineinfo(t->state,1) : NULL;
    t->history[(t->first+t->count)%HISTORY_LINES]=(struct line){copy,cols,next && next->continuation};
    t->count++; t->history_bytes+=bytes;
    t->line++;
    if (t->offset) t->offset=t->offset<t->count ? t->offset+1 : t->count;
    t->changed=true; return 1;
}
static int popline(int cols, VTermScreenCell *cells, void *user) {
    FT *t=user;
    if (!t->count) return 0;
    struct line *line=&t->history[(t->first+t->count-1)%HISTORY_LINES];
    memset(cells,0,(size_t)cols*sizeof *cells);
    VTermColor fg,bg;
    vterm_state_get_default_colors(t->state,&fg,&bg);
    for (int col=0;col<cols;col++) { cells[col].width=1; cells[col].fg=fg; cells[col].bg=bg; }
    memcpy(cells,line->cells,(size_t)(cols<line->cols ? cols : line->cols)*sizeof *cells);
    for (int col=0;col<cols;col++) cells[col].attrs.reverse^=t->reverse;
    t->history_bytes-=(size_t)line->cols*sizeof *line->cells;
    free(line->cells); *line=(struct line){0}; t->count--;
    t->line--;
    if (t->offset>t->count) t->offset=t->count;
    t->changed=true; return 1;
}
static int clear_history(void *user) {
    FT *t=user; while(t->count) drop_oldest(t); t->offset=0; t->changed=true; return 1;
}
static const VTermScreenCallbacks callbacks={
    .damage=damage, .movecursor=cursor, .settermprop=property,
    .sb_pushline=pushline, .sb_popline=popline, .sb_clear=clear_history,
};
static void *system_alloc(void *owner, size_t bytes) { (void)owner; return malloc(bytes); }
static void system_free(void *owner, void *pointer) { (void)owner; free(pointer); }
static void *terminal_alloc(size_t bytes, void *owner) {
    FT *t=owner;
    if (bytes>SIZE_MAX-sizeof(struct allocation)) longjmp(t->allocation_failure,1);
    struct allocation *allocation=t->allocator.alloc(t->allocator.owner,sizeof *allocation+bytes);
    if (!allocation) longjmp(t->allocation_failure,1);
    allocation->previous=NULL; allocation->next=t->allocations;
    if (allocation->next) allocation->next->previous=allocation;
    t->allocations=allocation;
    memset(allocation+1,0,bytes);
    return allocation+1;
}
static void terminal_free(void *pointer, void *owner) {
    if (!pointer) return;
    FT *t=owner;
    struct allocation *allocation=(struct allocation *)pointer-1;
    if (allocation->previous) allocation->previous->next=allocation->next;
    else t->allocations=allocation->next;
    if (allocation->next) allocation->next->previous=allocation->previous;
    t->allocator.free(t->allocator.owner,allocation);
}
static const VTermAllocatorFunctions terminal_allocator={terminal_alloc,terminal_free};
static void allocation_failed(FT *t) {
    /* An interrupted libvterm mutation is no longer safe to inspect or free
     * through its own object graph. Our allocation ledger owns every block. */
    while (t->allocations) terminal_free(t->allocations+1,t);
    t->vt=NULL; t->state=NULL; t->screen=NULL;
    t->error="Terminal ran out of memory"; t->changed=true;
    ft_close(t,true);
}
static bool enqueue(FT *t, const char *bytes, size_t len) {
    if (len>OUTPUT_BYTES-t->out_len) { t->error="Terminal input queue is full"; return false; }
    if (t->out_start+t->out_len+len>OUTPUT_BYTES) {
        memmove(t->output,t->output+t->out_start,t->out_len); t->out_start=0;
    }
    memcpy(t->output+t->out_start+t->out_len,bytes,len); t->out_len+=len; return true;
}
static void output(const char *bytes, size_t len, void *user) { (void)enqueue(user,bytes,len); }

FT *ft_new(int rows, int cols) {
    return ft_new_alloc(rows,cols,NULL);
}
FT *ft_new_alloc(int rows, int cols, const FT_Allocator *allocator) {
    if (rows<1 || rows>GRID_MAX || cols<2 || cols>GRID_MAX) return NULL;
    FT_Allocator a=allocator ? *allocator : (FT_Allocator){NULL,system_alloc,system_free};
    if (!a.alloc || !a.free) return NULL;
    FT *t=a.alloc(a.owner,sizeof *t);
    if (!t) return NULL;
    memset(t,0,sizeof *t); t->allocator=a;
    t->master=t->channel=t->process=-1;
    t->rows=rows; t->cols=cols; t->cursor_visible=true; t->cursor_shape=1;
    if (setjmp(t->allocation_failure)) { allocation_failed(t); ft_free(t); return NULL; }
    t->vt=vterm_new_with_allocator(rows,cols,(VTermAllocatorFunctions *)&terminal_allocator,t);
    vterm_set_utf8(t->vt,1);
    t->state=vterm_obtain_state(t->vt);
    t->screen=vterm_obtain_screen(t->vt);
    vterm_output_set_callback(t->vt,output,t);
    vterm_screen_set_callbacks(t->screen,&callbacks,t);
    vterm_screen_enable_altscreen(t->screen,1);
    /* Physical rows remain stable in history. Screen/history resize clips and
     * pads, never silently reflows selections or joins unrelated commands. */
    vterm_screen_enable_reflow(t->screen,false);
    vterm_screen_set_damage_merge(t->screen,VTERM_DAMAGE_SCREEN);
    vterm_screen_reset(t->screen,1);
    return t;
}

static bool valid_shell(const char *path) {
    struct stat st;
    return path && path[0]=='/' && !stat(path,&st) && S_ISREG(st.st_mode) && !access(path,X_OK);
}
int ft_start(FT *t, const char *helper, const char *plugin, const char *directory, bool scope) {
    if (t->pid) return -1;
    const char *shell=getenv("SHELL");
    char account_buf[16384]; struct passwd account, *found=NULL;
    if (!valid_shell(shell)) {
        if (!getpwuid_r(getuid(),&account,account_buf,sizeof account_buf,&found) && found && valid_shell(found->pw_shell)) shell=found->pw_shell;
        else shell="/bin/sh";
    }
    int master=-1, slave=-1, pair[2]={-1,-1};
    struct winsize size={.ws_row=(unsigned short)t->rows,.ws_col=(unsigned short)t->cols};
    if (openpty(&master,&slave,NULL,NULL,&size)) goto failed;
    if (fcntl(master,F_SETFD,FD_CLOEXEC) || fcntl(slave,F_SETFD,FD_CLOEXEC) ||
        fcntl(master,F_SETFL,O_NONBLOCK) || socketpair(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC|SOCK_NONBLOCK,0,pair)) goto failed;
    int one=1;
    if (setsockopt(pair[0],SOL_SOCKET,SO_PASSCRED,&one,sizeof one)) goto failed;
    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions)) goto failed;
    int rc=0;
    for (int fd=0;fd<3;fd++) if (posix_spawn_file_actions_adddup2(&actions,slave,fd)) rc=1;
    if (posix_spawn_file_actions_adddup2(&actions,pair[1],3) ||
        posix_spawn_file_actions_addclosefrom_np(&actions,4)) rc=1;
    char *const args[]={(char *)helper,scope ? "1" : "0",(char *)directory,(char *)shell,(char *)plugin,NULL};
    if (!rc) rc=posix_spawn(&t->pid,helper,&actions,NULL,args,environ);
    posix_spawn_file_actions_destroy(&actions);
    if (rc) { errno=rc; goto failed; }
    close(slave); close(pair[1]); t->master=master; t->channel=pair[0];
    t->process=rediwm_child_open(t->pid);
    if (t->process<0) { ft_close(t,true); t->error="Could not watch terminal process"; return -1; }
    t->changed=true; return 0;
failed:
    if (master>=0) close(master);
    if (slave>=0) close(slave);
    if (pair[0]>=0) close(pair[0]);
    if (pair[1]>=0) close(pair[1]);
    t->pid=0; t->error="Could not launch terminal"; return -1;
}
void ft_resize(FT *t, int rows, int cols) {
    if (!t->vt) return;
    if (rows<1 || rows>GRID_MAX || cols<2 || cols>GRID_MAX || (rows==t->rows && cols==t->cols)) return;
    if (setjmp(t->allocation_failure)) { allocation_failed(t); return; }
    t->rows=rows; t->cols=cols;
    vterm_set_size(t->vt,rows,cols); vterm_screen_flush_damage(t->screen);
    if (t->master>=0) {
        struct winsize size={.ws_row=(unsigned short)rows,.ws_col=(unsigned short)cols};
        (void)ioctl(t->master,TIOCSWINSZ,&size);
    }
    t->changed=true;
}
void ft_feed(FT *t, const char *bytes, size_t len) {
    if (!t->vt) return;
    if (setjmp(t->allocation_failure)) { allocation_failed(t); return; }
    vterm_input_write(t->vt,bytes,len); vterm_screen_flush_damage(t->screen);
}
int ft_pty(const FT *t) { return t->master; }
int ft_channel(const FT *t) { return t->channel; }
int ft_exit_fd(const FT *t) { return t->exited ? -1 : t->process; }
bool ft_wants_write(const FT *t) { return t->out_len>0 && !t->eof; }
bool ft_wants_request(const FT *t) { return t->channel>=0 && t->request_queued; }

static void flush_output(FT *t) {
    if (t->master<0 || !t->out_len) return;
    size_t n=t->out_len<READ_BUDGET ? t->out_len : READ_BUDGET;
    ssize_t written=write(t->master,t->output+t->out_start,n);
    if (written>0) { t->out_start+=(size_t)written; t->out_len-=(size_t)written; if (!t->out_len) t->out_start=0; }
    else if (written<0 && errno!=EINTR && errno!=EAGAIN) t->out_len=0;
}
static void integration(FT *t) {
    for (int i=0;i<32 && t->channel>=0;i++) {
        struct ft_status status;
        struct iovec iov={&status,sizeof status};
        char control[CMSG_SPACE(sizeof(struct ucred))];
        struct msghdr msg={.msg_iov=&iov,.msg_iovlen=1,.msg_control=control,.msg_controllen=sizeof control};
        ssize_t n=recvmsg(t->channel,&msg,MSG_DONTWAIT|MSG_TRUNC);
        if (n<0 && (errno==EAGAIN || errno==EINTR)) break;
        if (n<=0) { close(t->channel); t->channel=-1; t->status.flags=0; t->changed=true; break; }
        bool authenticated=false;
        for (struct cmsghdr *cm=CMSG_FIRSTHDR(&msg);cm;cm=CMSG_NXTHDR(&msg,cm)) {
            if (cm->cmsg_level==SOL_SOCKET && cm->cmsg_type==SCM_CREDENTIALS && cm->cmsg_len>=CMSG_LEN(sizeof(struct ucred))) {
                struct ucred peer; memcpy(&peer,CMSG_DATA(cm),sizeof peer);
                authenticated=peer.uid==getuid() && peer.pid==t->pid;
            }
        }
        if (authenticated && n==sizeof status && !(msg.msg_flags&(MSG_TRUNC|MSG_CTRUNC)) &&
            status.magic==FT_MAGIC && status.serial<=t->serial && memchr(status.path,0,sizeof status.path)) {
            t->status=status; t->changed=true;
        }
    }
    if (t->request_queued && t->channel>=0 &&
        send(t->channel,&t->request,sizeof t->request,MSG_DONTWAIT|MSG_NOSIGNAL)==sizeof t->request) t->request_queued=false;
}
/* A still-owned (possibly zombie) session leader reserves the session id, so
 * these signals cannot hit a reused pid. Detached setsid jobs are independent.
 * Runs only during session teardown, never on an idle or output path. */
static void signal_session(FT *t, int sig) {
    if (t->pid<=0 || t->exited || getsid(t->pid)!=t->pid) return;
    DIR *proc=opendir("/proc");
    if (!proc) return;
    struct dirent *entry;
    while ((entry=readdir(proc))) {
        char *end; long value=strtol(entry->d_name,&end,10);
        if (!*entry->d_name || *end || value<=0 || value>INT_MAX || value==t->pid) continue;
        pid_t pid=(pid_t)value;
        int member=rediwm_child_open(pid);
        if (member<0) continue;
        if (getsid(pid)==t->pid) (void)rediwm_child_signal(member,sig);
        rediwm_child_close(member);
    }
    closedir(proc);
}
void ft_io(FT *t, bool read_pty, bool write_pty, bool channel, bool exited) {
    if (read_pty && t->master>=0) {
        char bytes[8192];
        for (size_t used=0;used<READ_BUDGET;) {
            ssize_t n=read(t->master,bytes,sizeof bytes);
            if (n<0 && errno==EINTR) continue;
            if (n<0 && errno==EAGAIN) break;
            if (n<=0) { close(t->master); t->master=-1; t->eof=true; t->out_len=0; t->changed=true; break; }
            used+=(size_t)n; ft_feed(t,bytes,(size_t)n);
        }
    }
    if (write_pty) flush_output(t);
    if (channel) integration(t);
    if (exited && t->pid>0 && !t->exited) {
        int status=0;
        /* Readiness of the exit descriptor proves exit; retain the zombie until all remaining
         * members of this terminal's session have received their final signal. */
        signal_session(t,SIGKILL);
        pid_t rc=waitpid(t->pid,&status,WNOHANG);
        if (rc==t->pid || (rc<0 && errno==ECHILD)) {
            t->exited=true; t->exit_status=WIFEXITED(status) ? WEXITSTATUS(status) : 128+WTERMSIG(status);
            t->changed=true;
        }
    }
}
bool ft_changed(FT *t) { bool changed=t->changed; t->changed=false; return changed; }
bool ft_running(const FT *t) { return t->pid>0 && !t->exited; }
/* Whether closing would end work: a foreground job on the PTY, or any other
 * process of the session (background jobs, nested shells, ssh). An idle shell
 * at its prompt is not work. Read from the kernel at the moment of asking, so
 * it cannot be stale, and anything that cannot be established counts as
 * active. Runs only when the window is asked to close. */
bool ft_active(const FT *t) {
    if (!ft_running(t)) return false;
    if (t->master<0 || tcgetpgrp(t->master)!=t->pid || getsid(t->pid)!=t->pid) return true;
    DIR *proc=opendir("/proc");
    if (!proc) return true;
    bool active=false;
    struct dirent *entry;
    while (!active && (entry=readdir(proc))) {
        char *end; long value=strtol(entry->d_name,&end,10);
        if (!*entry->d_name || *end || value<=0 || value>INT_MAX || value==t->pid) continue;
        active=getsid((pid_t)value)==t->pid;
    }
    closedir(proc);
    return active;
}
bool ft_exited(const FT *t) { return t->exited; }
int ft_exit_status(const FT *t) { return t->exit_status; }
const char *ft_error(const FT *t) { return t->error; }
void ft_close(FT *t, bool force) {
    if (t->pid>0 && !t->exited) {
        int signal=force ? SIGKILL : SIGHUP;
        signal_session(t,signal);
        if (t->process>=0) (void)rediwm_child_signal(t->process,signal);
        else (void)kill(t->pid,signal);
    }
}
void ft_free(FT *t) {
    if (!t) return;
    ft_close(t,true);
    if (t->pid>0 && !t->exited) (void)waitpid(t->pid,NULL,WNOHANG);
    if (t->master>=0) close(t->master);
    if (t->channel>=0) close(t->channel);
    if (t->process>=0) rediwm_child_close(t->process);
    while(t->count) drop_oldest(t);
    if (t->vt) vterm_free(t->vt);
    while (t->allocations) terminal_free(t->allocations+1,t);
    t->allocator.free(t->allocator.owner,t);
}
int ft_follow(FT *t, const char *directory) {
    if (!directory || directory[0]!='/' || strlen(directory)>=FT_PATH || t->channel<0) return -1;
    t->request=(struct ft_request){.magic=FT_MAGIC,.serial=++t->serial};
    strcpy(t->request.path,directory); t->request_queued=true;
    integration(t); t->changed=true; return 0;
}
const struct ft_status *ft_status(const FT *t) { return &t->status; }
bool ft_pending(const FT *t) { return t->serial>t->status.serial; }
void ft_palette(FT *t, int index, uint8_t r, uint8_t g, uint8_t b) {
    if (!t->vt) return;
    VTermColor color; vterm_color_rgb(&color,r,g,b);
    if (index>=0 && index<16) vterm_state_set_palette_color(t->state,index,&color);
    else {
        VTermColor fg,bg; vterm_state_get_default_colors(t->state,&fg,&bg);
        if (index==-1) fg=color; else bg=color;
        vterm_state_set_default_colors(t->state,&fg,&bg);
    }
}
bool ft_cell(FT *t, int row, int col, FT_Cell *cell) {
    if (row<0 || row>=t->rows || col<0 || col>=t->cols) return false;
    return ft_cell_at(t,t->line-t->offset+row,col,cell);
}
int64_t ft_line(const FT *t) { return t->line; }
bool ft_cell_at(FT *t, int64_t line_number, int col, FT_Cell *cell) {
    if (!t->vt) return false;
    if (line_number<t->line-t->count || line_number>=t->line+t->rows || col<0 || col>=t->cols) return false;
    VTermScreenCell source={0};
    int pos=t->count+(int)(line_number-t->line);
    if (pos<t->count) {
        const struct line *line=&t->history[(t->first+pos)%HISTORY_LINES];
        if (col<line->cols) source=line->cells[col];
        else {
            source.width=1;
            vterm_state_get_default_colors(t->state,&source.fg,&source.bg);
        }
        source.attrs.reverse^=t->reverse;
    } else if (!vterm_screen_get_cell(t->screen,(VTermPos){pos-t->count,col},&source)) return false;
    memset(cell,0,sizeof *cell);
    memcpy(cell->chars,source.chars,sizeof cell->chars);
    cell->width=source.width;
    if (source.chars[0]==UINT32_MAX) cell->width=0;
    cell->attrs=(source.attrs.bold ? FT_BOLD : 0) | (source.attrs.italic ? FT_ITALIC : 0) |
        (source.attrs.underline ? FT_UNDERLINE : 0) | (source.attrs.strike ? FT_STRIKE : 0) |
        (source.attrs.reverse ? FT_REVERSE : 0) | (source.attrs.conceal ? FT_CONCEAL : 0);
    VTermColor default_fg,default_bg;
    vterm_state_get_default_colors(t->state,&default_fg,&default_bg);
    if (VTERM_COLOR_IS_DEFAULT_FG(&source.fg)) source.fg=default_fg;
    if (VTERM_COLOR_IS_DEFAULT_BG(&source.bg)) source.bg=default_bg;
    vterm_screen_convert_color_to_rgb(t->screen,&source.fg);
    vterm_screen_convert_color_to_rgb(t->screen,&source.bg);
    cell->fg[0]=source.fg.rgb.red; cell->fg[1]=source.fg.rgb.green; cell->fg[2]=source.fg.rgb.blue;
    cell->bg[0]=source.bg.rgb.red; cell->bg[1]=source.bg.rgb.green; cell->bg[2]=source.bg.rgb.blue;
    return true;
}
bool ft_wrapped(FT *t, int row) {
    return ft_wrapped_at(t,t->line-t->offset+row);
}
bool ft_wrapped_at(FT *t, int64_t line_number) {
    if (!t->vt) return false;
    if (line_number<t->line-t->count || line_number>=t->line+t->rows) return false;
    int pos=t->count+(int)(line_number-t->line);
    if (pos<t->count) return t->history[(t->first+pos)%HISTORY_LINES].wrapped;
    int next=pos-t->count+1;
    const VTermLineInfo *info=next<t->rows ? vterm_state_get_lineinfo(t->state,next) : NULL;
    return info && info->continuation;
}
int ft_history(const FT *t) { return t->count; }
size_t ft_history_bytes(const FT *t) { return t->history_bytes; }
int ft_offset(const FT *t) { return t->offset; }
void ft_scroll(FT *t, int lines) {
    if (t->alternate) return;
    int offset=t->offset+lines;
    if (offset<0) offset=0;
    if (offset>t->count) offset=t->count;
    if (offset!=t->offset) { t->offset=offset; t->changed=true; }
}
void ft_key(FT *t, uint32_t sym, const char *text, size_t len, int modifiers) {
    if (!t->vt) return;
    if (t->offset) { t->offset=0; t->changed=true; }
    VTermKey key=VTERM_KEY_NONE;
    switch (sym) {
    case XKB_KEY_Return: case XKB_KEY_KP_Enter: key=VTERM_KEY_ENTER; break;
    case XKB_KEY_Tab: case XKB_KEY_ISO_Left_Tab: key=VTERM_KEY_TAB; break;
    case XKB_KEY_BackSpace: key=VTERM_KEY_BACKSPACE; break;
    case XKB_KEY_Escape: key=VTERM_KEY_ESCAPE; break;
    case XKB_KEY_Up: key=VTERM_KEY_UP; break;
    case XKB_KEY_Down: key=VTERM_KEY_DOWN; break;
    case XKB_KEY_Left: key=VTERM_KEY_LEFT; break;
    case XKB_KEY_Right: key=VTERM_KEY_RIGHT; break;
    case XKB_KEY_Insert: key=VTERM_KEY_INS; break;
    case XKB_KEY_Delete: key=VTERM_KEY_DEL; break;
    case XKB_KEY_Home: key=VTERM_KEY_HOME; break;
    case XKB_KEY_End: key=VTERM_KEY_END; break;
    case XKB_KEY_Page_Up: key=VTERM_KEY_PAGEUP; break;
    case XKB_KEY_Page_Down: key=VTERM_KEY_PAGEDOWN; break;
    default:
        if (sym>=XKB_KEY_F1 && sym<=XKB_KEY_F35) key=VTERM_KEY_FUNCTION(sym-XKB_KEY_F1+1);
        break;
    }
    if (key!=VTERM_KEY_NONE) vterm_keyboard_key(t->vt,key,modifiers);
    else if (modifiers&(VTERM_MOD_CTRL|VTERM_MOD_ALT)) {
        uint32_t ch=xkb_keysym_to_utf32(sym);
        if (ch) vterm_keyboard_unichar(t->vt,ch,modifiers);
    } else {
        /* XKB/compose and IME commits are valid UTF-8. Decode with an explicit
         * bound; malformed input is replaced, never read beyond the slice. */
        for (size_t i=0;i<len;) {
            unsigned char ch=(unsigned char)text[i++]; uint32_t cp=ch; int more=0;
            if (ch>=0xc2 && ch<=0xdf) { cp=ch&31; more=1; }
            else if (ch>=0xe0 && ch<=0xef) { cp=ch&15; more=2; }
            else if (ch>=0xf0 && ch<=0xf4) { cp=ch&7; more=3; }
            else if (ch>=0x80) cp=0xfffd;
            if (i+(size_t)more>len) { cp=0xfffd; more=0; }
            for (int j=0;j<more;j++) {
                unsigned char c=(unsigned char)text[i];
                if ((c&0xc0)!=0x80) { cp=0xfffd; break; }
                cp=(cp<<6)|(c&63); i++;
            }
            if (cp>0x10ffff || (cp>=0xd800 && cp<=0xdfff)) cp=0xfffd;
            vterm_keyboard_unichar(t->vt,cp,0);
        }
    }
}
bool ft_paste(FT *t, const char *bytes, size_t len) {
    if (!t->vt) return false;
    if (len>OUTPUT_BYTES-t->out_len-((OUTPUT_BYTES-t->out_len)>=16 ? 16 : 0) || OUTPUT_BYTES-t->out_len<16) return false;
    t->offset=0; t->changed=true;
    vterm_keyboard_start_paste(t->vt);
    /* Drop ESC and other control bytes so pasted text cannot close bracketed
     * paste or inject terminal replies. Keep tabs and convert LF to CR. */
    for (size_t i=0;i<len;i++) {
        unsigned char ch=(unsigned char)bytes[i];
        if (ch=='\n') ch='\r';
        if ((ch>=32 && ch!=127) || ch=='\r' || ch=='\t') (void)enqueue(t,(char *)&ch,1);
    }
    vterm_keyboard_end_paste(t->vt); return true;
}
void ft_mouse(FT *t, int row, int col, int button, bool pressed, int modifiers) {
    if (!t->vt) return;
    if (row<0) row=0;
    if (row>=t->rows) row=t->rows-1;
    if (col<0) col=0;
    if (col>=t->cols) col=t->cols-1;
    vterm_mouse_move(t->vt,row,col,modifiers);
    if (button) vterm_mouse_button(t->vt,button,pressed,modifiers);
}
int ft_mouse_mode(const FT *t) { return t->mouse; }
void ft_focus(FT *t, bool focused) {
    if (!t->vt) return;
    if (focused) vterm_state_focus_in(t->state); else vterm_state_focus_out(t->state);
    t->changed=true;
}
bool ft_cursor(const FT *t, int *row, int *col, int *shape) {
    *row=t->cursor.row; *col=t->cursor.col; *shape=t->cursor_shape;
    return t->cursor_visible && !t->offset;
}
int ft_rows(const FT *t) { return t->rows; }
int ft_cols(const FT *t) { return t->cols; }
#ifdef FT_TEST
size_t ft_take_output(FT *t, char *bytes, size_t capacity) {
    size_t n=capacity<t->out_len ? capacity : t->out_len;
    memcpy(bytes,t->output+t->out_start,n); t->out_start+=n; t->out_len-=n;
    if (!t->out_len) t->out_start=0;
    return n;
}
#endif

#define _GNU_SOURCE
#include <archive.h>
#include <archive_entry.h>
#include <cairo.h>
#include <librsvg/rsvg.h>
#include "thumb_codec.h"
#include <webp/decode.h>
#include <png.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/landlock.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#define MAX_ENTRIES 4000
#define MAX_FILE (40u * 1024u * 1024u)
#define MAX_TOTAL (128u * 1024u * 1024u)
static char problem[4096];
static unsigned entries;
static uint64_t total;
extern int rediwm_theme_safe_path(const char *);
// The syscall policy is built and loaded in syscall_policy.zig.
extern int rediwm_theme_syscall_policy(void);
const char *rediwm_theme_problem(void) { return problem; }
static int fail(const char *file, const char *rule) {
    snprintf(problem, sizeof(problem), "%s: %s", file, rule); return -1;
}
static int suffix(const char *p, const char *s) {
    size_t n = strlen(p), m = strlen(s); return n >= m && !strcasecmp(p+n-m,s);
}
static int allowed(const char *p, int directory) {
    if (!rediwm_theme_safe_path(p)) return 0;
    if (!strcmp(p,"theme.toml") || !strcmp(p,"preview.png") || !strcmp(p,"logo.svg") || !strcmp(p,"logo.png")) return !directory;
    if (!strncmp(p,"README",6) || !strncmp(p,"LICENSE",7)) return !strchr(p,'/');
    const char *slash = strchr(p,'/');
    if (!slash) return directory && (!strcmp(p,"wallpapers") || !strcmp(p,"glyphs") || !strcmp(p,"icons") || !strcmp(p,"cursors"));
    if (!strncmp(p,"cursors/",8)) {
        if (!strcmp(p,"cursors/index.theme")) return !directory;
        if (!strcmp(p,"cursors/cursors")) return directory;
        return !directory && !strncmp(p,"cursors/cursors/",16) && !strchr(p+16,'/');
    }
    if (directory || strchr(slash+1,'/')) return 0;
    if (!strncmp(p,"wallpapers/",11)) return suffix(p,".png") || suffix(p,".jpg") || suffix(p,".jpeg") || suffix(p,".webp");
    if (!strncmp(p,"glyphs/",7)) return suffix(p,".svg");
    if (!strncmp(p,"icons/",6)) return suffix(p,".svg") || suffix(p,".png");
    return 0;
}
static int alias(const char *path, const char *target) {
    return !strncmp(path,"cursors/cursors/",16) && !strchr(path+16,'/') && target && *target && !strchr(target,'/') && rediwm_theme_safe_path(target);
}
static int parent_dirs(const char *path) {
    char copy[4096]; if (strlen(path)>=sizeof(copy)) return -1;
    strcpy(copy,path);
    for(char *p=copy+1;*p;p++) if(*p=='/') {
        *p=0; if(mkdir(copy,0700)<0 && errno!=EEXIST) return -1;
        struct stat st; if(lstat(copy,&st)<0 || !S_ISDIR(st.st_mode)) return -1;
        *p='/';
    }
    return 0;
}
static int copy_file(const char *src, const char *dst) {
    if(parent_dirs(dst)<0) return fail(dst,"cannot create parent");
    int in=open(src,O_RDONLY|O_NOFOLLOW|O_CLOEXEC),out=-1;
    if(in<0) return fail(src,"cannot open regular file");
    struct stat st; if(fstat(in,&st)<0 || !S_ISREG(st.st_mode)) {close(in);return fail(src,"regular files only");}
    out=open(dst,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(out<0) {close(in);return fail(dst,"cannot create file");}
    char buf[65536]; uint64_t bytes=0; ssize_t n; int rc=0;
    while((n=read(in,buf,sizeof(buf)))>0) {
        bytes+=(uint64_t)n;total+=(uint64_t)n;
        if(bytes>MAX_FILE || total>MAX_TOTAL) {rc=fail(src,"unpacked byte limit exceeded");break;}
        ssize_t off=0;while(off<n) {ssize_t w=write(out,buf+off,n-off);if(w<=0){rc=fail(dst,"write failed");break;}off+=w;}
        if(rc) break;
    }
    if(n<0) rc=fail(src,"read failed");
    close(in);if(fsync(out)<0) rc=fail(dst,"fsync failed");close(out);return rc;
}
static int walk_copy(const char *root,const char *rel,const char *dest) {
    char path[4096];if(snprintf(path,sizeof(path),"%s%s%s",root,*rel?"/":"",rel)>=(int)sizeof(path))return fail(rel,"path too long");
    DIR *dir=opendir(path);if(!dir)return fail(path,"cannot open directory");
    struct dirent *e;int rc=0;
    while((e=readdir(dir))) {
        if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;
        char child[4096],src[4096],dst[4096];
        if(snprintf(child,sizeof(child),"%s%s%s",rel,*rel?"/":"",e->d_name)>=(int)sizeof(child) ||
           snprintf(src,sizeof(src),"%s/%s",root,child)>=(int)sizeof(src) ||
           snprintf(dst,sizeof(dst),"%s/%s",dest,child)>=(int)sizeof(dst)) {rc=fail(rel,"path too long");break;}
        struct stat st;
        if(++entries>MAX_ENTRIES){rc=fail(child,"entry limit exceeded");break;}
        if(lstat(src,&st)<0){rc=fail(child,"stat failed");break;}
        if(S_ISLNK(st.st_mode)) {
            char target[4096];ssize_t n=readlink(src,target,sizeof(target)-1);if(n<0){rc=fail(child,"readlink failed");break;}target[n]=0;
            if(!alias(child,target)){rc=fail(child,"symlink not a cursor alias");break;}
            if(parent_dirs(dst)<0 || symlink(target,dst)<0){rc=fail(child,"alias create failed");break;}
        } else if(S_ISDIR(st.st_mode)) {
            if(!allowed(child,1)){rc=fail(child,"directory not allowed");break;}
            if(mkdir(dst,0700)<0){rc=fail(child,"mkdir failed");break;}
            rc=walk_copy(root,child,dest);if(rc)break;
        } else if(S_ISREG(st.st_mode)) {
            if(!allowed(child,0)){rc=fail(child,"file not allowed");break;}
            rc=copy_file(src,dst);if(rc)break;
        } else {rc=fail(child,"special files forbidden");break;}
    }
    closedir(dir);return rc;
}
int rediwm_theme_stage(const char *source,const char *dest) {
    entries=0;total=0;problem[0]=0;
    struct stat st;if(lstat(source,&st)<0)return fail(source,"source missing");
    if(S_ISDIR(st.st_mode))return walk_copy(source,"",dest);
    if(!S_ISREG(st.st_mode))return fail(source,"regular ZIP or directory required");
    struct archive *a=archive_read_new();if(!a)return fail(source,"allocation failed");
    archive_read_support_format_zip(a);archive_read_support_filter_none(a);
    int rc=0,status;struct archive_entry *e;
    if(archive_read_open_filename(a,source,65536)!=ARCHIVE_OK){rc=fail(source,"ZIP required");goto done;}
    while((status=archive_read_next_header(a,&e))==ARCHIVE_OK) {
        const char *raw=archive_entry_pathname(e);char name[4096];
        if(!raw || !rediwm_theme_safe_path(raw) || strlen(raw)>=sizeof(name)){rc=fail(raw?raw:source,"unsafe archive path");break;}
        strcpy(name,raw);size_t n=strlen(name);while(n && name[n-1]=='/')name[--n]=0;
        if(!n)continue;
        if(++entries>MAX_ENTRIES){rc=fail(name,"entry limit exceeded");break;}
        mode_t type=archive_entry_filetype(e);
        if(archive_entry_hardlink(e) || archive_entry_is_encrypted(e)){rc=fail(name,"hardlinks and encryption forbidden");break;}
        // Names are checked after unwrapping the optional top-level directory.
        char path[4096];if(snprintf(path,sizeof(path),"%s/%s",dest,name)>=(int)sizeof(path)){rc=fail(name,"path too long");break;}
        if(parent_dirs(path)<0){rc=fail(name,"unsafe parent");break;}
        if(type==AE_IFDIR){if(mkdir(path,0700)<0 && errno!=EEXIST){rc=fail(name,"mkdir failed");break;}continue;}
        if(type==AE_IFLNK) {
            const char *t=archive_entry_symlink(e);const char *p=name;
            if(strncmp(p,"cursors/",8)) {const char *slash=strchr(p,'/');if(slash)p=slash+1;}
            if(!alias(p,t)||symlink(t,path)<0){rc=fail(name,"symlink not a cursor alias");break;}continue;
        }
        if(type!=AE_IFREG){rc=fail(name,"special files forbidden");break;}
        int fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
        if(fd<0){rc=fail(name,"duplicate or unsafe file");break;}
        uint64_t bytes=0;char buf[65536];ssize_t got;
        while((got=archive_read_data(a,buf,sizeof(buf)))>0) {
            bytes+=(uint64_t)got;total+=(uint64_t)got;
            if(bytes>MAX_FILE || total>MAX_TOTAL){rc=fail(name,"unpacked byte limit exceeded");break;}
            ssize_t off=0;while(off<got){ssize_t w=write(fd,buf+off,got-off);if(w<=0){rc=fail(name,"write failed");break;}off+=w;}if(rc)break;
        }
        if(got<0)rc=fail(name,"invalid ZIP data");
        if(fsync(fd)<0)rc=fail(name,"fsync failed");close(fd);if(rc)break;
    }
    if(!rc && status!=ARCHIVE_EOF)rc=fail(source,"invalid ZIP");
 done:archive_read_free(a);return rc;
}
// Validate Adam7 PNGs row by row across their passes; no full-size raster.
static int png_stream_validate(const char *file,int *width,int *height) {
    FILE *input=fopen(file,"rb");if(!input)return 0;
    png_structp png=png_create_read_struct(PNG_LIBPNG_VER_STRING,NULL,NULL,NULL);
    png_infop info=png?png_create_info_struct(png):NULL;
    if(!info){if(png)png_destroy_read_struct(&png,NULL,NULL);fclose(input);return 0;}
    void *volatile row=NULL;
    if(setjmp(png_jmpbuf(png))) {free((void*)row);png_destroy_read_struct(&png,&info,NULL);fclose(input);return 0;}
    png_set_user_limits(png,16384,16384);png_init_io(png,input);png_read_info(png,info);
    *width=(int)png_get_image_width(png,info);*height=(int)png_get_image_height(png,info);
    int passes=png_set_interlace_handling(png);png_read_update_info(png,info);
    row=calloc(1,png_get_rowbytes(png,info));if(!row)png_error(png,"row allocation failed");
    for(int pass=0;pass<passes;pass++)for(int y=0;y<*height;y++)png_read_row(png,(png_bytep)row,NULL);
    png_read_end(png,NULL);free((void*)row);png_destroy_read_struct(&png,&info,NULL);fclose(input);return 1;
}
// Xcursor is little-endian: a file header, a TOC, then typed chunks.
// Only metadata is needed here; validate every size, without loading pixels.
static int cursor_words(FILE *input, uint64_t offset, uint32_t *words, size_t count) {
    unsigned char bytes[36]; // Largest read: the nine-word image header.
    if (count > sizeof(bytes)/4 || fseeko(input, (off_t)offset, SEEK_SET) != 0 ||
        fread(bytes, 4, count, input) != count) return 0;
    for (size_t i=0; i<count; i++) {
        const unsigned char *p=bytes+4*i;
        words[i]=(uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
    }
    return 1;
}
static int cursor_size_compare(const void *a, const void *b) {
    uint32_t x=*(const uint32_t *)a, y=*(const uint32_t *)b;
    return (x>y)-(x<y);
}
static int cursor_validate(const char *file) {
    const uint32_t image_type=0xfffd0002;
    FILE *input=fopen(file,"rb");
    if (!input) return 0;
    int valid=0;
    uint32_t *sizes=NULL;
    struct stat st;
    uint32_t header[4];
    if (fstat(fileno(input),&st)<0 || !S_ISREG(st.st_mode) || st.st_size<16 ||
        (uint64_t)st.st_size>MAX_FILE || !cursor_words(input,0,header,4)) goto done;
    uint64_t length=(uint64_t)st.st_size;
    // Keep the format's extension headers, but reject incompatible major versions.
    if (header[0]!=0x72756358 || header[1]<16 || header[1]>length ||
        header[2]>>16!=1 || header[3]==0 || header[3]>65536 ||
        header[3]>(length-header[1])/12) goto done;
    uint64_t toc_end=header[1]+(uint64_t)header[3]*12;
    sizes=malloc((size_t)header[3]*sizeof(*sizes));
    if (!sizes) goto done;
    size_t images=0;
    for (uint32_t i=0; i<header[3]; i++) {
        uint32_t toc[3], chunk[9];
        if (!cursor_words(input,header[1]+(uint64_t)i*12,toc,3)) goto done;
        uint64_t position=toc[2];
        if (position<toc_end || position>length || length-position<16 ||
            !cursor_words(input,position,chunk,4) || chunk[0]<16 ||
            chunk[0]>length-position || chunk[1]!=toc[0] || chunk[2]!=toc[1]) goto done;
        // Unknown chunk types (including comments) do not affect cursor images.
        if (toc[0]!=image_type) continue;
        if (chunk[0]<36 || chunk[2]==0 || chunk[3]==0 ||
            !cursor_words(input,position,chunk,9)) goto done;
        uint32_t width=chunk[4], height=chunk[5];
        if (width==0 || height==0 || width>512 || height>512 ||
            chunk[6]>=width || chunk[7]>=height ||
            (uint64_t)width*height*4>length-position-chunk[0]) goto done;
        sizes[images++]=toc[1];
    }
    if (images==0) goto done;
    // The 256-frame limit applies independently to each nominal size.
    qsort(sizes,images,sizeof(*sizes),cursor_size_compare);
    size_t frames=1;
    for (size_t i=1; i<images; i++) {
        frames=sizes[i]==sizes[i-1]?frames+1:1;
        if (frames>256) goto done;
    }
    valid=1;
done:
    free(sizes);
    fclose(input);
    return valid;
}
static int validate_file(const char *file,const char *rel,off_t bytes) {
    if(!strncmp(rel,"cursors/cursors/",16)) {
        return cursor_validate(file)?0:fail(rel,"invalid or oversized Xcursor file");
    }
    if(suffix(rel,".svg")) {
        size_t limit=!strncmp(rel,"glyphs/",7)?65536:512*1024;
        if(bytes<0||(uint64_t)bytes>limit)return fail(rel,"SVG byte limit exceeded");
        gchar *data=NULL;gsize size=0;GError *error=NULL;
        if(!g_file_get_contents(file,&data,&size,&error)){if(error)g_error_free(error);return fail(rel,"SVG read failed");}
        // No base URI: SVG references cannot read external resources.
        RsvgHandle *handle=rsvg_handle_new_from_data((guint8*)data,size,&error);g_free(data);
        if(!handle){if(error)g_error_free(error);return fail(rel,"invalid SVG");}
        cairo_surface_t *surface=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,256,256);cairo_t *cr=cairo_create(surface);
        RsvgRectangle viewport={0,0,256,256};struct timespec before,after;
        clock_gettime(CLOCK_MONOTONIC,&before);gboolean ok=rsvg_handle_render_document(handle,cr,&viewport,&error);clock_gettime(CLOCK_MONOTONIC,&after);
        int64_t ns=(after.tv_sec-before.tv_sec)*1000000000ll+after.tv_nsec-before.tv_nsec;
        cairo_destroy(cr);cairo_surface_destroy(surface);g_object_unref(handle);if(error)g_error_free(error);
        if(!ok)return fail(rel,"SVG render failed");
        if(!strncmp(rel,"glyphs/",7)&&ns>10000000)return fail(rel,"glyph render exceeded 10 ms");
    } else if(suffix(rel,".png")||suffix(rel,".jpg")||suffix(rel,".jpeg")||suffix(rel,".webp")) {
        gchar *data=NULL;gsize size=0;GError *error=NULL;
        if(!g_file_get_contents(file,&data,&size,&error)){if(error)g_error_free(error);return fail(rel,"image read failed");}
        int w=0,h=0,ok=0;
        if(suffix(rel,".webp")) {
            WebPDecoderConfig cfg;
            if(WebPInitDecoderConfig(&cfg) && WebPGetFeatures((uint8_t*)data,size,&cfg.input)==VP8_STATUS_OK) {
                w=cfg.input.width;h=cfg.input.height;
                if(w>0&&h>0&&w<=16384&&h<=16384) {
                    cfg.options.use_scaling=1;cfg.options.scaled_width=w>256?256:w;cfg.options.scaled_height=h>256?256:h;
                    ok=WebPDecode((uint8_t*)data,size,&cfg)==VP8_STATUS_OK;WebPFreeDecBuffer(&cfg.output);
                }
            }
        } else {
            tc_image image={0};int rc=suffix(rel,".png")?tc_png((uint8_t*)data,size,256,16384ll*16384,&image):tc_jpeg((uint8_t*)data,size,256,16384ll*16384,&image);
            ok=rc==TC_OK;w=image.src_w;h=image.src_h;tc_free(&image);
            if(rc==TC_UNSUPPORTED && suffix(rel,".png"))ok=png_stream_validate(file,&w,&h);
        }
        g_free(data);
        if(!ok||w<=0||h<=0||w>16384||h>16384)return fail(rel,"image decode failed or dimensions exceed 16384");
        if(!strcmp(rel,"preview.png")&&(w>512||h>320))return fail(rel,"preview exceeds 512x320");
    }
    return 0;
}
static int validate_tree(const char *root,const char *rel) {
    char path[4096];if(snprintf(path,sizeof(path),"%s%s%s",root,*rel?"/":"",rel)>=(int)sizeof(path))return fail(rel,"path too long");
    DIR *dir=opendir(path);if(!dir)return fail(path,"directory unreadable");
    int rc=0;struct dirent *e;
    while((e=readdir(dir))) {
        if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;
        char child[4096],full[4096];
        if(snprintf(child,sizeof(child),"%s%s%s",rel,*rel?"/":"",e->d_name)>=(int)sizeof(child)||snprintf(full,sizeof(full),"%s/%s",root,child)>=(int)sizeof(full)){rc=fail(rel,"path too long");break;}
        struct stat st;if(lstat(full,&st)<0){rc=fail(child,"stat failed");break;}
        if(++entries>MAX_ENTRIES){rc=fail(child,"entry limit exceeded");break;}
        if(S_ISLNK(st.st_mode)) {
            char target[4096];ssize_t n=readlink(full,target,sizeof(target)-1);if(n<0){rc=fail(child,"readlink failed");break;}target[n]=0;
            if(!alias(child,target)){rc=fail(child,"symlink not a cursor alias");break;}
            char resolved[4096];if(snprintf(resolved,sizeof(resolved),"%s/cursors/cursors/%s",root,target)>=(int)sizeof(resolved) || lstat(resolved,&st)<0 || !S_ISREG(st.st_mode)){rc=fail(child,"alias target must be a cursor file");break;}
        } else if(!allowed(child,S_ISDIR(st.st_mode))){rc=fail(child,"file or directory not allowed");break;}
        else if(S_ISDIR(st.st_mode)){rc=validate_tree(root,child);if(rc)break;}
        else if(S_ISREG(st.st_mode)) {
            if(st.st_size<0 || (uint64_t)st.st_size>MAX_FILE || (total+=(uint64_t)st.st_size)>MAX_TOTAL){rc=fail(child,"byte limit exceeded");break;}
            if(!strncmp(child,"icons/",6)&&st.st_size>512*1024){rc=fail(child,"icon exceeds 512 KiB");break;}
            rc=validate_file(full,child,st.st_size);if(rc)break;
        } else {rc=fail(child,"special files forbidden");break;}
    }
    closedir(dir);return rc;
}
int rediwm_theme_validate(const char *root) {entries=0;total=0;return validate_tree(root,"");}
int rediwm_theme_publish(const char *staging,const char *destination) {
    struct stat st;
    if(lstat(destination,&st)==0) {
        if(!S_ISDIR(st.st_mode))return fail(destination,"existing destination is not a directory");
        if(syscall(SYS_renameat2,AT_FDCWD,staging,AT_FDCWD,destination,2)<0)return fail(destination,"atomic replacement failed");
    } else if(errno!=ENOENT || rename(staging,destination)<0)return fail(destination,"atomic install failed");
    return 0;
}
static int pack_tree(struct archive *a,const char *root,const char *rel) {
    char full[4096];if(snprintf(full,sizeof(full),"%s/%s",root,rel)>=(int)sizeof(full))return fail(rel,"path too long");
    DIR *dir=opendir(full);if(!dir)return fail(rel,"cannot open directory");
    int rc=0;struct dirent *e;
    while((e=readdir(dir))) {
        if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;
        char child[4096],file[4096];
        if(snprintf(child,sizeof(child),"%s%s%s",rel,*rel?"/":"",e->d_name)>=(int)sizeof(child)||snprintf(file,sizeof(file),"%s/%s",root,child)>=(int)sizeof(file)){rc=fail(rel,"path too long");break;}
        struct stat st;if(lstat(file,&st)<0){rc=fail(child,"stat failed");break;}
        struct archive_entry *entry=archive_entry_new();archive_entry_set_pathname(entry,child);archive_entry_set_perm(entry, S_ISDIR(st.st_mode)?0700:0600);
        if(S_ISLNK(st.st_mode)){char target[4096];ssize_t n=readlink(file,target,sizeof(target)-1);if(n<0){archive_entry_free(entry);rc=fail(child,"readlink failed");break;}target[n]=0;archive_entry_set_filetype(entry,AE_IFLNK);archive_entry_set_symlink(entry,target);}
        else {archive_entry_set_filetype(entry,S_ISDIR(st.st_mode)?AE_IFDIR:AE_IFREG);archive_entry_set_size(entry,S_ISDIR(st.st_mode)?0:st.st_size);}
        if(archive_write_header(a,entry)!=ARCHIVE_OK)rc=fail(child,"ZIP header write failed");
        archive_entry_free(entry);
        if(!rc && S_ISREG(st.st_mode)) {
            int fd=open(file,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0){rc=fail(child,"read failed");break;}
            char buf[65536];ssize_t n;while((n=read(fd,buf,sizeof(buf)))>0)if(archive_write_data(a,buf,n)!=n){rc=fail(child,"ZIP write failed");break;}
            close(fd);if(n<0)rc=fail(child,"read failed");
        } else if(!rc && S_ISDIR(st.st_mode))rc=pack_tree(a,root,child);
        if(rc)break;
    }
    closedir(dir);return rc;
}
int rediwm_theme_pack(const char *root,const char *output) {
    int fd=open(output,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return fail(output,"output already exists or cannot be created");
    struct archive *a=archive_write_new();archive_write_set_format_zip(a);int rc=0;
    if(archive_write_open_fd(a,fd)!=ARCHIVE_OK)rc=fail(output,"cannot write ZIP");else rc=pack_tree(a,root,"");
    if(archive_write_close(a)!=ARCHIVE_OK&&!rc)rc=fail(output,"ZIP close failed");archive_write_free(a);if(fsync(fd)<0&&!rc)rc=fail(output,"fsync failed");close(fd);if(rc)unlink(output);return rc;
}
int rediwm_theme_copy(const char *src,const char *dst) {total=0;return copy_file(src,dst);}

// Image and SVG parsers run in a disposable child with no writable filesystem
// or networking. The parent performs publication only after this child exits.
static int parser_sandbox(const char *root, const char *source, int writable) {
    struct rlimit memory={512u*1024u*1024u,512u*1024u*1024u};
    if(setrlimit(RLIMIT_AS,&memory)<0)return -1;
    if(prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)<0)return -1;
#ifdef SYS_landlock_create_ruleset
    int abi=syscall(SYS_landlock_create_ruleset,NULL,0,LANDLOCK_CREATE_RULESET_VERSION);
    if(abi>0) {
        uint64_t access=LANDLOCK_ACCESS_FS_EXECUTE|LANDLOCK_ACCESS_FS_WRITE_FILE|LANDLOCK_ACCESS_FS_READ_FILE|LANDLOCK_ACCESS_FS_READ_DIR|LANDLOCK_ACCESS_FS_REMOVE_DIR|LANDLOCK_ACCESS_FS_REMOVE_FILE|LANDLOCK_ACCESS_FS_MAKE_CHAR|LANDLOCK_ACCESS_FS_MAKE_DIR|LANDLOCK_ACCESS_FS_MAKE_REG|LANDLOCK_ACCESS_FS_MAKE_SOCK|LANDLOCK_ACCESS_FS_MAKE_FIFO|LANDLOCK_ACCESS_FS_MAKE_BLOCK|LANDLOCK_ACCESS_FS_MAKE_SYM;
        if(abi>=2)access|=LANDLOCK_ACCESS_FS_REFER;
        if(abi>=3)access|=LANDLOCK_ACCESS_FS_TRUNCATE;
        struct landlock_ruleset_attr attr={.handled_access_fs=access};
        int rules=syscall(SYS_landlock_create_ruleset,&attr,sizeof(attr),0);
        if(rules<0)return -1;
        const char *paths[]={root,"/usr","/etc","/proc","/dev",source};
        for(size_t i=0;i<sizeof(paths)/sizeof(paths[0]);i++) {
            if(!paths[i])continue;
            int fd=open(paths[i],O_PATH|O_CLOEXEC);if(fd<0)continue;
            struct landlock_path_beneath_attr rule={.allowed_access=LANDLOCK_ACCESS_FS_READ_FILE|LANDLOCK_ACCESS_FS_READ_DIR,.parent_fd=fd};
            if(i==0 && writable)rule.allowed_access=access & ~LANDLOCK_ACCESS_FS_EXECUTE;
            struct stat st;if(fstat(fd,&st)==0 && !S_ISDIR(st.st_mode))rule.allowed_access=LANDLOCK_ACCESS_FS_READ_FILE;
            if(i==1)rule.allowed_access|=LANDLOCK_ACCESS_FS_EXECUTE;
            int rc=syscall(SYS_landlock_add_rule,rules,LANDLOCK_RULE_PATH_BENEATH,&rule,0);close(fd);
            if(rc<0){close(rules);return -1;}
        }
        int rc=syscall(SYS_landlock_restrict_self,rules,0);close(rules);if(rc<0)return -1;
    }
#endif
    return rediwm_theme_syscall_policy();
}
int rediwm_theme_validate_isolated(const char *root) {
    struct stat st;if(lstat(root,&st)<0||!S_ISDIR(st.st_mode))return fail(root,"pack root must be a directory");
    int pipefd[2];if(pipe2(pipefd,O_CLOEXEC)<0)return fail(root,"validation pipe failed");
    pid_t pid=fork();if(pid<0){close(pipefd[0]);close(pipefd[1]);return fail(root,"validation fork failed");}
    if(pid==0) {
        close(pipefd[0]);alarm(5);
        if(parser_sandbox(root,NULL,0)<0) {fail(root,"parser sandbox failed");{ssize_t sent=write(pipefd[1],problem,strlen(problem));(void)sent;}_exit(1);}
        int rc=rediwm_theme_validate(root);
        if(rc){ssize_t sent=write(pipefd[1],problem,strlen(problem));(void)sent;}
        _exit(rc?1:0);
    }
    close(pipefd[1]);ssize_t n=read(pipefd[0],problem,sizeof(problem)-1);close(pipefd[0]);if(n>0)problem[n]=0;
    int status;while(waitpid(pid,&status,0)<0)if(errno!=EINTR)return fail(root,"validation wait failed");
    if(!WIFEXITED(status)||WEXITSTATUS(status)!=0) {if(n>0)return -1;return fail(root,"parser failed or exceeded time limit");}
    return 0;
}

int rediwm_theme_stage_isolated(const char *source,const char *dest) {
    int pipefd[2];if(pipe2(pipefd,O_CLOEXEC)<0)return fail(source,"extraction pipe failed");
    pid_t pid=fork();if(pid<0){close(pipefd[0]);close(pipefd[1]);return fail(source,"extraction fork failed");}
    if(pid==0) {
        close(pipefd[0]);alarm(20);
        if(parser_sandbox(dest,source,1)<0) {fail(source,"archive sandbox failed");{ssize_t sent=write(pipefd[1],problem,strlen(problem));(void)sent;}_exit(1);}
        int rc=rediwm_theme_stage(source,dest);
        if(rc){ssize_t sent=write(pipefd[1],problem,strlen(problem));(void)sent;}
        _exit(rc?1:0);
    }
    close(pipefd[1]);ssize_t n=read(pipefd[0],problem,sizeof(problem)-1);close(pipefd[0]);if(n>0)problem[n]=0;
    int status;while(waitpid(pid,&status,0)<0)if(errno!=EINTR)return fail(source,"extraction wait failed");
    if(!WIFEXITED(status)||WEXITSTATUS(status)!=0) {if(n>0)return -1;return fail(source,"archive parser failed or exceeded time limit");}
    return 0;
}

int rediwm_theme_rollback(const char *staging,const char *destination) {
    struct stat st;
    if(lstat(staging,&st)==0) {
        if(syscall(SYS_renameat2,AT_FDCWD,staging,AT_FDCWD,destination,2)<0)return fail(destination,"install rollback failed");
    } else if(errno!=ENOENT || rename(destination,staging)<0)return fail(destination,"install rollback failed");
    return 0;
}

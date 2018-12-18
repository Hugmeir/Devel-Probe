#define PERL_NO_GET_CONTEXT     /* we want efficiency */
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#define PROBE_CONFIG "/tmp/devel-probe-config.cfg"

static Perl_ppaddr_t nextstate_orig = 0;
static int probe_enabled = 0;
static HV* probe_hash = 0;

static void probe_install(pTHX);
static OP*  probe_nextstate(pTHX);

static SV* trigger_cb = (SV*)NULL;

static inline void invoke_callback(const char* file, int line, SV* callback)
{
    int count;

    dSP;

    ENTER; SAVETMPS;
    PUSHMARK (SP);
    EXTEND(SP, 2);
    XPUSHs(sv_2mortal(newSVpv(file, 0)));
    XPUSHs(sv_2mortal(newSViv(line)));

    PUTBACK;
    count = call_sv (callback, G_VOID|G_DISCARD);
    if (count != 0) {
        croak("probe trigger should have zero return values");
    }

    FREETMPS; LEAVE;
}


static int probe_lookup(const char* file, int line, int create)
{
    U32 klen = strlen(file);
    SV** rlines = hv_fetch(probe_hash, file, klen, 0);
    HV* lines = 0;
    char kstr[20];

    if (rlines) {
        lines = (HV*) SvRV(*rlines);
        // fprintf(stderr, "PROBE found entry for file [%s]: %p\n", file, lines);
    } else if (!create) {
        return 0;
    } else {
        SV* slines = 0;
        lines = newHV();
        slines = (SV*) newRV((SV*) lines);
        hv_store(probe_hash, file, klen, slines, 0);
        // fprintf(stderr, "PROBE created entry for file [%s]: %p\n", file, lines);
    }

    klen = sprintf(kstr, "%d", line);
    if (!create) {
        SV** rflag = hv_fetch(lines, kstr, klen, 0);
        return rflag && SvTRUE(*rflag);
    } else {
        SV* flag = &PL_sv_yes;
        hv_store(lines, kstr, klen, flag, 0);
        // fprintf(stderr, "PROBE created entry for line [%s]\n", kstr);
    }

    return 1;
}

static void probe_dump(void)
{
    hv_iterinit(probe_hash);
    while (1) {
        SV* key = 0;
        SV* value = 0;
        char* kstr = 0;
        STRLEN klen = 0;
        HV* lines = 0;
        HE* entry = hv_iternext(probe_hash);
        if (!entry) {
            break; /* no more hash keys */
        }
        key = hv_iterkeysv(entry);
        if (!key) {
            continue; /* invalid key */
        }
        kstr = SvPV(key, klen);
        if (!kstr) {
            continue; /* invalid key */
        }
        fprintf(stderr, "PROBE dump file [%s]\n", kstr);

        value = hv_iterval(probe_hash, entry);
        if (!value) {
            continue; /* invalid value */
        }
        lines = (HV*) SvRV(value);
        hv_iterinit(lines);
        while (1) {
            SV* key = 0;
            SV* value = 0;
            char* kstr = 0;
            STRLEN klen = 0;
            HE* entry = hv_iternext(lines);
            if (!entry) {
                break; /* no more hash keys */
            }
            key = hv_iterkeysv(entry);
            if (!key) {
                continue; /* invalid key */
            }
            kstr = SvPV(key, klen);
            if (!kstr) {
                continue; /* invalid key */
            }
            value = hv_iterval(lines, entry);
            if (!value || !SvTRUE(value)) {
                continue;
            }
            fprintf(stderr, "PROBE dump line [%s]\n", kstr);
        }
    }
}

static void probe_install(pTHX)
{
    if (PL_ppaddr[OP_NEXTSTATE] == probe_nextstate) {
        croak("probe_install called twice");
    }

    nextstate_orig = PL_ppaddr[OP_NEXTSTATE];
    PL_ppaddr[OP_NEXTSTATE] = probe_nextstate;
    // fprintf(stderr, "PROBE nextstate_orig is [%p]\n", nextstate_orig);
}

static OP* probe_nextstate(pTHX)
{
    OP* ret = nextstate_orig(aTHX);

    do {
        const char* file = 0;
        int line = 0;

        if (!probe_enabled) {
            break;
        }

        file = CopFILE(PL_curcop);
        line = CopLINE(PL_curcop);
        // it isn't always obvious what file path is being used (e.g., what you should put in the cfg file)
        // fprintf(stderr, "file %s and line %d\n", file, line);
        if (!probe_lookup(file, line, 0)) {
            break;
        }

        if (trigger_cb != (SV*)NULL) {
            invoke_callback(file, line, trigger_cb);
        }
    } while (0);

    return ret;
}

static int skip_chars(const char* buf, int pos, int ws)
{
    while (!!isspace(buf[pos]) == !!ws) {
        if (buf[pos] == '#') {
            break;
        }
        ++pos;
    }
    return pos;
}

static void probe_check(pTHX_ const char* signal)
{
    FILE* fp = 0;

    time_t now = time(0);
    struct tm* tm = localtime(&now);
    fprintf(stderr, "PROBE check %s %04d-%02d-%02d %02d:%02d:%02d\n", signal, tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday, tm->tm_hour, tm->tm_min, tm->tm_sec);
    probe_enabled = 0;
    do {
        fp = fopen(PROBE_CONFIG, "r");
        if (!fp) {
            break;
        }

        while (1) {
            char buf[1024];
            int ini = 0;
            int pos = 0;

            if (!fgets(buf, 1024, fp)) {
                break;
            }

            ini = 0;
            pos = skip_chars(buf, ini, 1);
            if (buf[pos] == '\0') {
                continue;
            }
            if (buf[pos] == '#') {
                continue;
            }
            ini = pos;
            pos = skip_chars(buf, ini, 0);
            // fprintf(stderr, "[%*.*s]\n", pos - ini, pos - ini, buf + ini);
            if (memcmp(buf + ini, "enable", pos - ini) == 0) {
                fprintf(stderr, "PROBE enable\n");
                probe_enabled = 1;
                continue;
            }
            if (memcmp(buf + ini, "disable", pos - ini) == 0) {
                fprintf(stderr, "PROBE disable\n");
                probe_enabled = 0;
                continue;
            }
            if (memcmp(buf + ini, "dump", pos - ini) == 0) {
                fprintf(stderr, "PROBE dump\n");
                probe_dump();
                continue;
            }
            if (memcmp(buf + ini, "clear", pos - ini) == 0) {
                fprintf(stderr, "PROBE clear\n");
                probe_hash = newHV();
                continue;
            }
            if (memcmp(buf + ini, "probe", pos - ini) == 0) {
                char file[1024];

                ini = pos;
                pos = skip_chars(buf, ini, 1);
                if (buf[pos] == '\0') {
                    continue;
                }
                if (buf[pos] == '#') {
                    continue;
                }
                ini = pos;
                pos = skip_chars(buf, ini, 0);
                memcpy(file, buf + ini, pos - ini);
                file[pos - ini] = '\0';
                fprintf(stderr, "PROBE file [%s]\n", file);

                while (1) {
                    int j = 0;
                    int line = 0;

                    ini = pos;
                    pos = skip_chars(buf, ini, 1);
                    if (buf[pos] == '\0') {
                        break;
                    }
                    if (buf[pos] == '#') {
                        break;
                    }
                    ini = pos;
                    pos = skip_chars(buf, ini, 0);
                    line = 0;
                    for (j = ini; j < pos; ++j) {
                        line = line * 10 + buf[j] - '0';
                    }
                    fprintf(stderr, "PROBE line [%d]\n", line);
                    probe_lookup(file, line, 1);
                }
                continue;
            }
        }
    } while (0);

    if (fp) {
        fclose(fp);
        fp = 0;
    }
}

MODULE = Devel::Probe        PACKAGE = Devel::Probe
PROTOTYPES: DISABLE

#################################################################

void
install(HV* options)
PREINIT:
    SV** opt_check = 0;
CODE:
    probe_install(aTHX);
    probe_hash = newHV();

    opt_check = hv_fetch(options, "check", 5, 0);
    if (opt_check && SvTRUE(*opt_check)) {
        probe_check(aTHX_ "_INIT_");
    }

void
check(const char* signal)
PREINIT:
CODE:
    probe_check(aTHX_ signal);

void
trigger(SV* callback)
CODE:
    if (trigger_cb == (SV*)NULL) {
        trigger_cb = newSVsv(callback);
    } else {
        SvSetSV(trigger_cb, callback);
    }

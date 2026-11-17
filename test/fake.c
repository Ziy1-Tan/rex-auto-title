/*
 * A stand-in for codex, claude, or pi in the end-to-end test. It writes a
 * conversation where the real agent would, under FAKE_HOME, then waits:
 *
 *   codex   a thread row in FAKE_HOME/.codex/state_5.sqlite (via sqlite3)
 *   claude  FAKE_HOME/.claude/projects/<folder>/<id>.jsonl
 *   pi      FAKE_HOME/.pi/agent/sessions/--<folder>--/<time>_<id>.jsonl
 *
 * Run as: APP [--prompt TEXT] [--name TEXT] [--none]. --none starts a chat
 * that hasn't written anything yet. Arguments, because a program Rex
 * starts gets Rex's environment rather than the caller's. Built by
 * test/e2e.sh with -DAPP="codex" (or claude, pi) and -DFAKE_HOME.
 */
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static void make_dirs(const char *path) {
  char buf[4096];
  snprintf(buf, sizeof buf, "%s", path);
  for (char *p = buf + 1; *p; p++) {
    if (*p == '/') {
      *p = 0;
      mkdir(buf, 0755);
      *p = '/';
    }
  }
  mkdir(buf, 0755);
}

static FILE *open_append(const char *dir, const char *file) {
  make_dirs(dir);
  FILE *f = fopen(file, "a");
  if (!f) { perror(file); exit(1); }
  return f;
}

int main(int argc, char **argv) {
  const char *app = APP;
  const char *prompt = "hello";
  const char *name = NULL;
  int none = 0;
  char id[128];
  snprintf(id, sizeof id, "00000000-0000-4000-8000-%012d", (int)getpid());
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--none")) { none = 1; continue; }
    if (i + 1 >= argc) break;
    if (!strcmp(argv[i], "--prompt")) prompt = argv[++i];
    else if (!strcmp(argv[i], "--name")) name = argv[++i];
    else if (!strcmp(argv[i], "--resume") || !strcmp(argv[i], "--session") || !strcmp(argv[i], "resume"))
      snprintf(id, sizeof id, "%s", argv[++i]);
  }

  char cwd[2048], dir[4096], file[4608];
  if (!getcwd(cwd, sizeof cwd)) return 1;
  if (none) {
    /* nothing written yet */
  } else if (!strcmp(app, "claude")) {
    char slug[2048];
    snprintf(slug, sizeof slug, "%s", cwd);
    for (char *p = slug; *p; p++) if (!isalnum((unsigned char)*p)) *p = '-';
    snprintf(dir, sizeof dir, "%s/.claude/projects/%s", FAKE_HOME, slug);
    snprintf(file, sizeof file, "%s/%s.jsonl", dir, id);
    FILE *f = open_append(dir, file);
    fprintf(f, "{\"type\":\"user\",\"origin\":{\"kind\":\"human\"},\"message\":{\"content\":\"%s\"}}\n", prompt);
    if (name) fprintf(f, "{\"type\":\"ai-title\",\"aiTitle\":\"%s\"}\n", name);
    fclose(f);
  } else if (!strcmp(app, "pi")) {
    char slug[2048];
    snprintf(slug, sizeof slug, "%s", cwd + 1);
    for (char *p = slug; *p; p++) if (*p == '/') *p = '-';
    snprintf(dir, sizeof dir, "%s/.pi/agent/sessions/--%s--", FAKE_HOME, slug);
    snprintf(file, sizeof file, "%s/2026-11-17T00-00-00-000Z_%s.jsonl", dir, id);
    FILE *f = open_append(dir, file);
    fprintf(f, "{\"type\":\"session\",\"id\":\"%s\",\"cwd\":\"%s\"}\n", id, cwd);
    fprintf(f, "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"%s\"}]}}\n", prompt);
    if (name) fprintf(f, "{\"type\":\"session_info\",\"name\":\"%s\"}\n", name);
    fclose(f);
  } else {
    snprintf(dir, sizeof dir, "%s/.codex", FAKE_HOME);
    make_dirs(dir);
    char sql[8192];
    long long now = (long long)time(NULL) * 1000;
    snprintf(sql, sizeof sql,
      "create table if not exists threads (id text primary key, rollout_path text, cwd text, "
      "title text, first_user_message text, name text, source text, archived integer, updated_at_ms integer);"
      "insert or replace into threads values ('%s', '', '%s', '%s', '%s', %s%s%s, 'cli', 0, %lld);",
      id, cwd, prompt, prompt, name ? "'" : "", name ? name : "null", name ? "'" : "", now);
    char cmd[12288];
    snprintf(cmd, sizeof cmd, "sqlite3 '%s/.codex/state_5.sqlite' \"%s\"", FAKE_HOME, sql);
    if (system(cmd) != 0) return 1;
  }
  printf("fake %s on %s\n", app, id);
  fflush(stdout);
  for (;;) pause();
}


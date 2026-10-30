// Installed setuid root. Runs a command with the caller's real UID and the
// effective UID of another user, as a setuid program that drops privileges
// with setreuid(2) does.
#include <pwd.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <user> <command> [args...]\n", argv[0]);
    return 2;
  }
  struct passwd *pw = getpwnam(argv[1]);
  if (pw == NULL) {
    fprintf(stderr, "%s: no such user\n", argv[1]);
    return 1;
  }
  if (setreuid(getuid(), pw->pw_uid) != 0) {
    perror("setreuid");
    return 1;
  }
  execv(argv[2], argv + 2);
  perror("execv");
  return 1;
}

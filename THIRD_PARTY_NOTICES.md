# Third-party notices

## GNU C Library (glibc)

`chargectl`, the program in the release downloads that switches charging, is
statically linked with the GNU C Library from Ubuntu 24.04's cross-compiler
packages (glibc 2.39).

- **Licence:** GNU Lesser General Public License, version 2.1 or later. Its
  full text is in `LGPL-2.1.txt` (in `licenses/` in the source repository).
- **Source:** https://www.gnu.org/software/libc/, and Ubuntu's `glibc` source
  package (https://launchpad.net/ubuntu/+source/glibc).
- **Relinking:** Charge Limit's complete source is in this repository, and
  `build.sh` rebuilds `chargectl`, so it can be relinked against a modified
  glibc.

GCC's runtime library, also linked in, is covered by the GCC Runtime Library
Exception, which places no conditions on the program.

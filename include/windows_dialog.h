#include <wchar.h>

/* Opens a dialog for the user to select a file. Returns a UTF-16 string
 * since that is what the Win32 API for the open dialog returns. */
wchar_t *windows_file_picker(void);

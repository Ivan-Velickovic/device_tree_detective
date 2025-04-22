/*
 * This file exists outside of the Zig code because I based it off
 * of "Native File Dialog" (https://github.com/mlabbe/nativefiledialog) which
 * uses C++ to deal with file dialogs on Windows.
 * The Win32 API is supposed to be compatible with C but all the official documentation
 * references C++ and so just to save me some time and because of how little of the Win32
 * API I actually need to access, I do it all in here with C++.
 */
#include <windows.h>
#include <shobjidl.h>

#define COM_INITFLAGS ::COINIT_APARTMENTTHREADED | ::COINIT_DISABLE_OLE1DDE

static BOOL COMIsInitialized(HRESULT coResult)
{
    if (coResult == RPC_E_CHANGED_MODE)
    {
        // TODO:
        // If COM was previously initialized with different init flags,
        // NFD still needs to operate. Eat this warning.
        return TRUE;
    }

    return SUCCEEDED(coResult);
}

static HRESULT COMInit(void)
{
    return ::CoInitializeEx(NULL, COM_INITFLAGS);
}

extern "C" wchar_t *windows_file_picker(void);

wchar_t *windows_file_picker(void) {
    HRESULT coResult = COMInit();
    if (!COMIsInitialized(coResult)) {
        // TODO, error log
        return NULL;
    }

    ::IFileOpenDialog *fileOpenDialog(NULL);
    HRESULT result = ::CoCreateInstance(::CLSID_FileOpenDialog, NULL,
                                        CLSCTX_ALL, ::IID_IFileOpenDialog,
                                        reinterpret_cast<void**>(&fileOpenDialog));
    if (!SUCCEEDED(result)) {
        // TODO: error
        return NULL;
    }

    result = fileOpenDialog->Show(NULL);
    if (SUCCEEDED(result)) {
        ::IShellItem *shellItem(NULL);
        result = fileOpenDialog->GetResult(&shellItem);
        if (!SUCCEEDED(result)) {
            // TODO: error
            return NULL;
        }

        wchar_t *filePath(NULL);
        result = shellItem->GetDisplayName(::SIGDN_FILESYSPATH, &filePath);
        if (!SUCCEEDED(result)) {
            // TODO: error
            shellItem->Release();
            return NULL;
        }

        return filePath;
    } else if (result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
        return NULL;
    } else {
        // TODO: error
        return NULL;
    }

    fileOpenDialog->Release();
    // COMuninit(coResult);

    return NULL;
}

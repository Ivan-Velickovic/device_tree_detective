#include "gtk_extern.h"

static void wait_for_cleanup(void)
{
    while (gtk_events_pending()) {
        gtk_main_iteration();
    }
}

// TODO: need to free with g_free
char *gtk_file_picker(void) {
    if (!gtk_init_check( NULL, NULL)) {
        return NULL;
    }

    char *filename = NULL;

    GtkWidget *dialog = gtk_file_chooser_dialog_new( "Open File",
                                          NULL,
                                          GTK_FILE_CHOOSER_ACTION_OPEN,
                                          "_Cancel", GTK_RESPONSE_CANCEL,
                                          "_Open", GTK_RESPONSE_ACCEPT,
                                          NULL );
    if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
        filename = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
    }

    wait_for_cleanup();
    gtk_widget_destroy(dialog);
    wait_for_cleanup();

    return filename;
}

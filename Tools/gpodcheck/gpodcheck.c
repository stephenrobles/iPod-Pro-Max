/* gpodcheck: reads an iPod (mount point) with libgpod and dumps what it sees.
 * Used only during development to verify databases written by iPod Pro Max.
 * Usage: gpodcheck <mountpoint>            dump tracks/playlists
 *        gpodcheck --write <mountpoint>    write a small libgpod-authored DB (for reader testing)
 */
#include <stdio.h>
#include <string.h>
#include "itdb.h"
#include <gdk-pixbuf/gdk-pixbuf.h>

static void dump(const char *mp) {
    GError *err = NULL;
    Itdb_iTunesDB *db = itdb_parse(mp, &err);
    if (!db) { fprintf(stderr, "PARSE FAILED: %s\n", err ? err->message : "?"); return; }
    printf("version=0x%x tracks=%d playlists=%d\n", db->version, g_list_length(db->tracks), g_list_length(db->playlists));
    for (GList *l = db->tracks; l; l = l->next) {
        Itdb_Track *t = l->data;
        printf("TRACK id=%u dbid=%llx title=\"%s\" artist=\"%s\" album=\"%s\" genre=\"%s\" path=\"%s\" len=%u size=%u nr=%u year=%u bitrate=%u sr=%u rating=%u pc=%u mediatype=%u art=%u flag4=%u unplayed=%u mhii=%u ft=\"%s\" rel=%ld url=\"%s\" desc=%d\n",
               t->id, (unsigned long long)t->dbid, t->title?t->title:"", t->artist?t->artist:"", t->album?t->album:"", t->genre?t->genre:"",
               t->ipod_path?t->ipod_path:"", t->tracklen, t->size, t->track_nr, t->year, t->bitrate, t->samplerate, t->rating, t->playcount, t->mediatype,
               t->has_artwork, t->flag4, t->mark_unplayed, t->mhii_link, t->filetype?t->filetype:"", (long)t->time_released, t->podcasturl?t->podcasturl:"", t->description ? (int)strlen(t->description) : 0);
        if (t->artwork && itdb_track_has_thumbnails(t)) {
            GdkPixbuf *pb = itdb_artwork_get_pixbuf(db->device, t->artwork, -1, -1);
            printf("   ARTWORK pixbuf=%s %dx%d\n", pb ? "ok" : "FAILED", pb ? gdk_pixbuf_get_width(pb) : 0, pb ? gdk_pixbuf_get_height(pb) : 0);
            if (pb) { gchar *fn = g_strdup_printf("/tmp/gpodcheck-art-%u.png", t->id); gdk_pixbuf_save(pb, fn, "png", NULL, NULL); g_free(fn); g_object_unref(pb); }
        }
    }
    for (GList *l = db->playlists; l; l = l->next) {
        Itdb_Playlist *p = l->data;
        printf("PLAYLIST \"%s\" master=%d podcast=%d smart=%d members=%d sort=%d\n", p->name, itdb_playlist_is_mpl(p), itdb_playlist_is_podcasts(p), p->is_spl, g_list_length(p->members), p->sortorder);
        int i = 0;
        for (GList *m = p->members; m && i < 200; m = m->next, i++) {
            Itdb_Track *t = m->data;
            printf("   - %s\n", t->title ? t->title : "?");
        }
    }
    itdb_free(db);
}

static void write_db(const char *mp) {
    GError *err = NULL;
    Itdb_iTunesDB *db = itdb_new();
    itdb_set_mountpoint(db, mp);
    Itdb_Playlist *mpl = itdb_playlist_new("gpod iPod", FALSE);
    itdb_playlist_set_mpl(mpl);
    itdb_playlist_add(db, mpl, -1);
    Itdb_Playlist *pod = itdb_playlist_new("Podcasts", FALSE);
    itdb_playlist_set_podcasts(pod);
    itdb_playlist_add(db, pod, -1);
    Itdb_Playlist *user = itdb_playlist_new("Road Trip", FALSE);
    itdb_playlist_add(db, user, -1);
    for (int i = 0; i < 5; i++) {
        Itdb_Track *t = itdb_track_new();
        t->title = g_strdup_printf("Song %d ünïcode ☃", i + 1);
        t->artist = g_strdup(i < 3 ? "The Testers" : "Another Artist");
        t->album = g_strdup(i < 3 ? "First Album" : "Second Album");
        t->genre = g_strdup("Rock");
        t->tracklen = 180000 + i * 1000;
        t->size = 4000000 + i;
        t->track_nr = i + 1;
        t->year = 2005;
        t->bitrate = 192;
        t->samplerate = 44100;
        t->rating = 80;
        t->playcount = i;
        t->mediatype = ITDB_MEDIATYPE_AUDIO;
        t->ipod_path = g_strdup_printf(":iPod_Control:Music:F%02d:GPOD%d.mp3", i, i);
        t->filetype = g_strdup("MPEG audio file");
        itdb_track_add(db, t, -1);
        itdb_playlist_add_track(mpl, t, -1);
        if (i % 2 == 0) itdb_playlist_add_track(user, t, -1);
    }
    for (int i = 0; i < 2; i++) {
        Itdb_Track *t = itdb_track_new();
        t->title = g_strdup_printf("Episode %d", i + 1);
        t->artist = g_strdup("Podcaster");
        t->album = g_strdup("Great Show");
        t->tracklen = 3600000;
        t->size = 50000000;
        t->mediatype = ITDB_MEDIATYPE_PODCAST;
        t->flag4 = 1;
        t->mark_unplayed = 2;
        t->remember_playback_position = 1;
        t->skip_when_shuffling = 1;
        t->time_released = 1700000000 + i * 86400;
        t->podcasturl = g_strdup("https://example.com/ep.mp3");
        t->podcastrss = g_strdup("https://example.com/feed.xml");
        t->description = g_strdup("An episode description.");
        t->ipod_path = g_strdup_printf(":iPod_Control:Music:F1%d:POD%d.mp3", i, i);
        t->filetype = g_strdup("MPEG audio file");
        itdb_track_add(db, t, -1);
        itdb_playlist_add_track(pod, t, -1);
    }
    if (!itdb_write(db, &err)) { fprintf(stderr, "WRITE FAILED: %s\n", err ? err->message : "?"); }
    else printf("wrote libgpod db to %s\n", mp);
    itdb_free(db);
}

static void dump_photos(const char *mp) {
    GError *err = NULL;
    Itdb_PhotoDB *db = itdb_photodb_parse(mp, &err);
    if (!db) { fprintf(stderr, "PHOTO PARSE FAILED: %s\n", err ? err->message : "?"); return; }
    printf("photos=%d albums=%d\n", g_list_length(db->photos), g_list_length(db->photoalbums));
    for (GList *l = db->photoalbums; l; l = l->next) {
        Itdb_PhotoAlbum *a = l->data;
        printf("ALBUM \"%s\" type=%d id=%d members=%d\n", a->name, a->album_type, a->album_id, g_list_length(a->members));
    }
    for (GList *l = db->photos; l; l = l->next) {
        Itdb_Artwork *p = l->data;
        printf("PHOTO id=%u size=%u\n", p->id, p->artwork_size);
        for (int fmt = 0; fmt < 2; fmt++) {
            GdkPixbuf *pb = itdb_artwork_get_pixbuf(db->device, p, fmt == 0 ? 720 : 130, fmt == 0 ? 480 : 88);
            if (pb) {
                gchar *fn = g_strdup_printf("/tmp/gpodcheck-photo-%u-%d.png", p->id, fmt);
                gdk_pixbuf_save(pb, fn, "png", NULL, NULL);
                printf("   PIXBUF %dx%d -> %s\n", gdk_pixbuf_get_width(pb), gdk_pixbuf_get_height(pb), fn);
                g_free(fn); g_object_unref(pb);
            } else printf("   PIXBUF FAILED\n");
        }
    }
    itdb_photodb_free(db);
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--photos") == 0) { dump_photos(argv[2]); return 0; }
    if (argc == 3 && strcmp(argv[1], "--write") == 0) { write_db(argv[2]); return 0; }
    if (argc != 2) { fprintf(stderr, "usage: gpodcheck [--write] <mountpoint>\n"); return 1; }
    dump(argv[1]);
    return 0;
}

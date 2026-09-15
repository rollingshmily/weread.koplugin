# WeRead eink highlight / thought upload

Upload is eink-only. Web gateway is unchanged.

## Evidence

APK `2.1.2.10245900` Retrofit `@JSONField` in `NoteService` / `BaseSingleReviewService`, then live-proved on 2026-09-16 with a test eink login (`vid=937872265`, book `695233`).

### Paths

| Action | Method | Path | Live response |
|---|---|---|---|
| Add underline | POST | `/book/addBookmark` | `{bookmarkId}` |
| Update underline style | POST | `/book/updateBookmark` | `{succ}` |
| Remove underline | POST | `/book/removeBookmark` | `{succ}` |
| Add thought | POST | `/review/add` | `{reviewId, createTime}` |
| Edit thought text | POST | `/review/useredit` | `{reviewId, userEditTime}` |
| Delete thought | POST | `/review/delete` | `{succ}` |

`/review/edit` only updates range, not thought text. Edits use `/review/useredit`.

### addBookmark body (APK + live)

`bookId`, `chapterUid`, `type`, `range`, `markText`, `bookVersion`, `style`

- `type = 1` (APK `addUnderLine`; live `bookmarklist.updated[].type` is `1`)
- `bookVersion = 0`, `style = 0`
- Do **not** send `colorStyle`. Live bookmarklist items have `style`, not `colorStyle`.

### removeBookmark / updateBookmark

- remove: `bookmarkId`
- update: `bookmarkId`, `style`

### review/add body (APK chapterUid branch + live)

`bookId`, `content`, `chapterUid`, `range`, `abstract`, `type`, `bookVersion`, `isPrivate`, `friendship`, `htmlContent`, `title`, `notVisibleToFriends`

Empty `atUserVids` is omitted so Lua `{}` is not encoded as a JSON object.

### review/useredit body (live)

`reviewId`, `content`, `isPrivate`, `friendship`, `notVisibleToFriends`, `type`, `bookId`, `chapterUid`, `range`, `abstract`

### review/delete

`reviewId`

### bookmarklist item keys (live)

`bookmarkId`, `bookId`, `bookVersion`, `chapterUid`, `chapterIdx`, `chapterName`, `range`, `markText`, `style`, `type`, `createTime`

## Range

Same as download: `"start-end"`, HTML rune index, 0-based, end exclusive, tags included when the visible quote wraps them. Reverse map (`Annotations.rangeFromMarkText`) uses original eink chapter HTML from the ZIP (no underline inject). Zero or 2+ matches → skip upload.

## Behaviour

- Not logged into eink: local KOReader save/delete still works, nothing is posted.
- Range lookup fail: skip upload, keep local mark.
- Remove without `bookmarkId` / `reviewId`: skip; do not invent an id.
- Combined EPUB uses `Chapters.at_xpointer`; single-chapter file uses `getChapterInfoFromFile`.

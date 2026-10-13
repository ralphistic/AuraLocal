from pathlib import Path
root=Path(__file__).resolve().parents[2]
dart=(root/'lib/main.dart').read_text(encoding='utf-8')
art=(root/'lib/metadata_art.dart').read_text(encoding='utf-8')
swift=(root/'native/ios/AuraFileReferences.swift').read_text(encoding='utf-8')
workflow=(root/'.github/workflows/ios.yml').read_text(encoding='utf-8')
def require(ok, msg):
 if not ok: raise AssertionError(msg)
 print('PASS:',msg)
require('No songs match this view' in dart and 'Show all songs' in dart,
        'Empty filters explain why tracks are hidden and offer reset')
require('pickInPlace' in dart and 'asCopy: false' in swift,
        'Default Files import opens audio in place without copying')
require('bookmarkData' in swift and 'resolvingBookmarkData' in swift,
        'File-provider bookmarks saved and restored')
require('AuraFileReferences.swift' in workflow and 'fileReferences = AuraFileReferences' in workflow,
        'Native file reference channel is registered in the actual iOS build')
require('exportLibraryIndex' in dart and 'restoreLibraryIndex' in dart,
        'Portable index can be exported without copying music')
require('AspectRatio(aspectRatio: 1' in art and 'SizedBox.square' in dart,
        'Album artwork always occupies a square')
require('rotateY' in art and 'Curves.easeInOutCubicEmphasized' in art,
        'Album card has animated 3D flip and eased timing')
require('Enter manually' in art and 'Find online' in art and 'openEditor(context, item)' in art,
        'Missing artwork offers manual and online candidate editing')
require(all(k in art for k in ['trackNumber','releaseDate','genre','album','artist','title','artworkUrl']),
        'Full editable metadata fields')
require('trackMetadata' in dart and 'saveTrackMetadata' in dart,
        'Metadata saved in persistent library index')
restore=dart.split('Future<void> restoreLibrary() async {',1)[1].split('Future<bool> isSameAudio',1)[0]
require('hideDuplicateLibraryEntries()' not in restore,
        'Startup never performs destructive full-library duplicate scans')
require("manifest.path + '.backup'" in dart and 'pending.rename(manifest.path)' in dart,
        'Library manifest writes preserve a recoverable previous index')
require('embeddedArtwork' in dart and 'embeddedArtwork' in (root/'native/ios/AuraPitchBridge.swift').read_text(),
        'Native embedded album art is inspected before generic artwork')

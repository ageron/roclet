// Portable project sources. Compiler and package-cache files belong to the
// workspace engine and are never stored as part of an editable notebook.
const encoder = new TextEncoder();
export function projectPath(path) {
  if (typeof path !== 'string' || !path || path.length > 480 || path.startsWith('/') || /[\\:\u0000-\u001f\u007f]/u.test(path)
      || path.split('/').some(part => !part || part === '.' || part === '..') || path === 'Main.roc') {
    throw new Error('Use a relative project path, such as Geometry.roc or shapes/Wall.roc. Main.roc is reserved for the notebook.');
  }
  return path;
}
export function projectFiles(files = []) {
  if (!Array.isArray(files) || files.length > 256) throw new Error('A notebook supports up to 256 project files.');
  const paths = new Set(); let size = 0;
  return files.map(file => {
    const path = projectPath(file?.path);
    if (typeof file.source !== 'string' || paths.has(path)) throw new Error('Project files need text contents and unique paths.');
    paths.add(path); size += encoder.encode(file.source).length;
    if (size > 16 * 1024 * 1024) throw new Error('Project sources exceed the 16 MiB limit.');
    return {path, source:file.source};
  });
}

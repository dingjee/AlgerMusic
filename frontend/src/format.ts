/** 格式化工具。 */

/** 毫秒 -> mm:ss。 */
export function formatDuration(ms: number): string {
  if (!ms || ms < 0) return '--:--';
  const total = Math.floor(ms / 1000);
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
}

/** 字节 -> 可读大小。 */
export function formatSize(bytes: number): string {
  if (!bytes || bytes <= 0) return '-';
  const units = ['B', 'KB', 'MB', 'GB'];
  let value = bytes;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value.toFixed(value >= 100 || index === 0 ? 0 : 1)} ${units[index]}`;
}

/** 码率（bps）-> 可读文本。 */
export function formatBitrate(bps: number): string {
  if (!bps || bps <= 0) return '未知码率';
  return `${Math.round(bps / 1000)} kbps`;
}

/** 歌手列表 -> 文本。 */
export function artistText(artists: { name: string }[] | undefined): string {
  if (!artists || artists.length === 0) return '未知歌手';
  return artists.map((a) => a.name).join(' / ');
}

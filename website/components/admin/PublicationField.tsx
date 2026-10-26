/** Always submit a value, using the existing CMS parser's on/false contract.
 * This only edits the draft's requested state; publishing remains server-owned. */
export function PublicationField({ id, published = false }: { id: string; published?: boolean }) {
  const helpId = `${id}-help`;
  return <div>
    <label htmlFor={id} className="label-uten">发布后展示状态</label>
    <select id={id} name="published" defaultValue={published ? 'on' : 'false'} aria-describedby={helpId} className="input-uten">
      <option value="on">公开展示</option>
      <option value="false">暂不公开，保留内容</option>
    </select>
    <p id={helpId} className="mt-2 text-xs leading-6 text-muted-foreground">保存只生成草稿，只有审核发布此版本后，展示状态才会生效。</p>
  </div>;
}

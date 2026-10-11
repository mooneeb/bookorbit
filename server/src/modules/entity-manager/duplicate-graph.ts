import { UnprocessableEntityException } from '@nestjs/common';
import type { RawCandidatePair } from './strategies/entity-strategy.interface';

interface ClusterSummary {
  memberIds: Set<string>;
  sum: number;
  pairCount: number;
}

const MAX_CANDIDATE_ENTITIES = 200_000;

export class DuplicateGraph {
  private readonly parent = new Map<string, string>();
  private readonly clusters = new Map<string, ClusterSummary>();

  get entityCount(): number {
    return this.parent.size;
  }

  root(id: string): string {
    if (!this.parent.has(id)) return id;
    let root = id;
    while (this.parent.get(root) !== root) root = this.parent.get(root)!;
    while (id !== root) {
      const next = this.parent.get(id)!;
      this.parent.set(id, root);
      id = next;
    }
    return root;
  }

  add(pairs: RawCandidatePair[]): void {
    for (const pair of pairs) {
      for (const identity of [String(pair.idA), String(pair.idB)]) {
        if (!this.parent.has(identity)) {
          if (this.parent.size >= MAX_CANDIDATE_ENTITIES)
            throw new UnprocessableEntityException('Duplicate scan exceeds 200000 candidate entities. Select a library to narrow the scan.');
          this.parent.set(identity, identity);
          this.clusters.set(identity, { memberIds: new Set([identity]), sum: 0, pairCount: 0 });
        }
      }
      let rootA = this.root(String(pair.idA));
      let rootB = this.root(String(pair.idB));
      if (rootA !== rootB) {
        if (this.clusters.get(rootA)!.memberIds.size < this.clusters.get(rootB)!.memberIds.size) [rootA, rootB] = [rootB, rootA];
        const target = this.clusters.get(rootA)!;
        const source = this.clusters.get(rootB)!;
        this.parent.set(rootB, rootA);
        for (const member of source.memberIds) target.memberIds.add(member);
        target.sum += source.sum;
        target.pairCount += source.pairCount;
        this.clusters.delete(rootB);
      }
      const cluster = this.clusters.get(rootA)!;
      cluster.sum += pair.simScore;
      cluster.pairCount++;
    }
  }

  ranked(): Array<{ root: string; memberIds: Set<string>; avgSimilarity: number; pairCount: number }> {
    return [...this.clusters.entries()]
      .map(([root, cluster]) => ({
        root,
        memberIds: cluster.memberIds,
        avgSimilarity: cluster.sum / cluster.pairCount,
        pairCount: cluster.pairCount,
      }))
      .sort((a, b) => b.avgSimilarity - a.avgSimilarity || a.root.localeCompare(b.root));
  }
}

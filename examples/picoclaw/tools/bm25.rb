# frozen_string_literal: true

# BM25 — port of picoclaw's pkg/utils/bm25.go (k1=1.2, b=0.75). Identical
# scoring; the top-k min-heap is replaced by a sort (same results, simpler).
module BM25
  K1 = 1.2
  B = 0.75

  # Lowercase whitespace split, stripping edge punctuation.
  def self.tokenize(str)
    str.downcase.split.map { |t| t.gsub(/\A[.,;:!?"'()\/\\\-_]+|[.,;:!?"'()\/\\\-_]+\z/, "") }.reject(&:empty?)
  end

  class Engine
    # docs: array of [document, text] pairs (text = the searchable string).
    def initialize(docs)
      @docs = docs.map(&:first)
      n = docs.size
      entries = []
      df = Hash.new(0)
      total_len = 0

      docs.each do |_doc, text|
        tokens = BM25.tokenize(text)
        total_len += tokens.size
        tf = Hash.new(0)
        tokens.each { |t| tf[t] += 1 }
        tf.each_key { |term| df[term] += 1 }
        entries << tf
      end

      avg_len = n.zero? ? 1.0 : total_len.to_f / n
      avg_len = 1.0 if avg_len.zero?

      @entries = entries
      @idf = {}
      df.each do |term, freq|
        @idf[term] = Math.log((n - freq + 0.5) / (freq + 0.5) + 1)
      end
      @doc_len_norm = entries.map { |tf| K1 * (1 - B + B * tf.values.sum / avg_len) }
      @posting = Hash.new { |h, k| h[k] = [] }
      entries.each_with_index do |tf, i|
        tf.each_key { |term| @posting[term] << i }
      end
    end

    # Returns [[doc, score], ...] sorted by score desc, capped at top_k.
    def search(query, top_k)
      return [] if top_k <= 0 || @docs.empty?

      terms = BM25.tokenize(query).uniq
      return [] if terms.empty?

      scores = Hash.new(0.0)
      terms.each do |term|
        idf = @idf[term]
        next unless idf

        @posting[term].each do |doc_id|
          freq = @entries[doc_id][term].to_f
          scores[doc_id] += idf * (freq * (K1 + 1) / (freq + @doc_len_norm[doc_id]))
        end
      end

      scores.sort_by { |_, score| -score }.first(top_k).map { |id, score| [@docs[id], score] }
    end
  end
end

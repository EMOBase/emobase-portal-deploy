# SequenceServer extension that adds a "Genome Browser" link to BLAST hits
# that come from a genome nucleotide database.
#
# Loaded with: sequenceserver -r /opt/links_jbrowse2.rb
#
# emobase-genomics writes BLAST databases as /db/<assemblyID>-<type>, where
# <type> is genome, protein, or rna (see SetupBlastHandler). JBrowse2 names its
# assemblies with the same <assemblyID> (e.g. "v2a4"), so the assembly can be
# derived from the database name.
#
# JBrowse2 uses the genome assembly as the reference, so only hits against a
# *-genome nucleotide database can be located there. Protein and RNA hits have
# no coordinates in that assembly, and the link is omitted for them.
require 'json'

module SequenceServer
  module Links
    JBROWSE_CONFIG = ENV.fetch('JBROWSE_CONFIG', '/jbrowse2/data/config.json')

    def self.genome_database?(database)
      database.type == 'nucleotide' &&
        File.basename(database.name).match?(/(?:\A|-)genome\z/)
    end

    # Tracks selected for the assembly in the config's default session. This
    # mirrors what JBrowse2 shows at its bare /jbrowse/ URL, so the BLAST link
    # opens with the same tracks selected instead of every track in the config.
    def self.default_session_track_ids(config, assembly)
      Array(config.dig('defaultSession', 'views')).each do |view|
        # Newer configs nest these under "init"; older ones put them directly
        # on the view.
        init = view['init'] || view
        next unless init['assembly'] == assembly

        ids = Array(init['tracks']).filter_map do |track|
          track.is_a?(String) ? track : track['trackId']
        end
        return ids unless ids.empty?
      end
      nil
    end

    # Track IDs selected for the assembly by the JBrowse2 default session, plus
    # the ad-hoc track for this BLAST hit. If the config defines no default
    # session for the assembly, fall back to every track for that assembly.
    # The blast service mounts the jbrowse2-data volume read-only at /jbrowse2
    # for this lookup.
    def self.jbrowse_track_ids(assembly, session_track_id)
      config = JSON.parse(File.read(JBROWSE_CONFIG))
      ids = default_session_track_ids(config, assembly)
      ids ||= config.fetch('tracks', []).filter_map do |track|
        track['trackId'] if Array(track['assemblyNames']).include?(assembly)
      end
      (ids + [session_track_id]).uniq
    rescue StandardError
      [session_track_id]
    end

    def jbrowse2
      # Only a search against the genome database has coordinates in the
      # JBrowse2 assembly. Restricting this to a single selected database also
      # avoids whichdb(), which runs blastdbcmd per hit and would stall the
      # results page on large result sets.
      databases = report.querydb
      return nil unless databases.length == 1

      database = databases.first
      return nil unless Links.genome_database?(database)

      assembly = File.basename(database.name).sub(/-(?:genome|protein|rna)\z/, '')
      ref_name = id.gsub(/^.*\|(.*)\|.*$/, '\1')
      coords = coordinates[1]
      start_pos, end_pos = coords.min, coords.max
      # coordinates[1] is already [min, max], so take the direction from the
      # first HSP instead.
      first_hsp = hsps.first
      strand = first_hsp && first_hsp.sstart > first_hsp.send ? -1 : 1

      track_id = "blast_hit_#{object_id}"
      session_track = {
        type: 'FeatureTrack',
        trackId: track_id,
        name: "BLAST Hit: #{ref_name}",
        assemblyNames: [assembly],
        adapter: {
          type: 'FromConfigAdapter',
          features: [{
            uniqueId: "hit_#{track_id}",
            refName: ref_name,
            start: start_pos - 1, # JBrowse2 uses 0-based starts
            end: end_pos,         # and 1-based ends
            strand: strand,
            type: 'match'
          }]
        },
        displays: [{
          type: 'LinearBasicDisplay',
          displayId: "#{track_id}-LinearBasicDisplay"
        }]
      }

      # JBrowse2 is served by the portal itself, not by the species
      # deployment, so link to the portal's public origin. The species
      # deployment serves JBrowse2 under /jbrowse/.
      base_url = ENV.fetch('PUBLIC_SERVER', '').sub(%r{/+\z}, '')
      url = "#{base_url}/jbrowse/?config=data/config.json"
      url += "&assembly=#{encode(assembly)}"
      url += "&loc=#{encode(ref_name)}:#{start_pos}..#{end_pos}"
      url += "&tracks=#{encode(Links.jbrowse_track_ids(assembly, track_id).join(','))}"
      url += "&sessionTracks=#{encode([session_track].to_json)}"
      url += "&tracklist=true"

      {
        order: 1,
        title: 'Genome Browser',
        url: url,
        icon: 'fa-search-plus'
      }
    end
  end
end

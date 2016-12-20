
#
# specifying flor
#
# Mon Dec 19 13:25:20 JST 2016
#

require 'spec_helper'


describe 'Flor punit' do

  before :each do

    @executor = Flor::TransientExecutor.new
  end

  describe 'loop' do

    it 'loops' do

      flon = %{
        loop
          push f.l "$(nid)"
          break _ if "$(nid)" == "0_1_0_0-2"
      }

      r = @executor.launch(flon, payload: { 'l' => [] })

      expect(@executor.execution['nodes'].keys).to eq(%w[ 0 ])

      expect(r['point']).to eq('terminated')
      expect(r['payload']['l']).to eq(%w[ 0_0_1 0_0_1-1 0_0_1-2 ])
    end

    it 'understands "continue"' do

      flon = %{
        loop
          continue _ if "$(nid)" == "0_0_0_0-1"
          push f.l "$(nid)"
          break _ if "$(nid)" == "0_2_0_0-2"
      }

      r = @executor.launch(flon, payload: { 'l' => [] })

      expect(@executor.execution['nodes'].keys).to eq(%w[ 0 ])

      expect(r['point']).to eq('terminated')
      expect(r['payload']['l']).to eq(%w[ 0_1_1 0_1_1-2 ])
    end

#    it 'takes the first att child as tag' do
#
#      flon = %{
#        loop 'xyz'
#          break _ if "$(nid)" == "0_0_0_0-2"
#      }
#
#      r = @executor.launch(flon, journal: true)
#
#      expect(r['point']).to eq('terminated')
#
#      expect(
#        @executor.journal
#          .collect { |m|
#            [ m['point'], m['nid'], (m['tags'] || []).join(',') ].join(':') }
#          .join("\n")
#      ).to eq(%w[
#        execute:0:
#        execute:0_0:
#        execute:0_0_0:
#        receive:0_0:
#        receive:0:
#        entered:0:main
#        execute:0_1:
#        execute:0_1_0:
#        receive:0_1:
#        execute:0_1_1:
#        receive:0_1:
#        receive:0:
#        receive::
#        left:0:main
#        terminated::
#      ].join("\n"))
#    end
  end
end

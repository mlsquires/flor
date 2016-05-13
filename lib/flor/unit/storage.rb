#--
# Copyright (c) 2015-2016, John Mettraux, jmettraux+flon@gmail.com
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# Made in Japan.
#++


module Flor

  class Storage

    attr_reader :unit, :db

    def initialize(unit)

      @unit = unit
      @db = connect
    end

    def shutdown

      @db.disconnect
    end

    def migrate(to=nil, from=nil)

      dir = @unit.conf['db_migrations'] || 'migrations'

      Sequel::Migrator.apply(@db, dir, to, from)
    end

    def clear

      [ :flon_messages, :flon_executions, :flon_timers, :flon_logs ].each do |t|
        @db[t].delete
      end
    end

    def load_exids

      @db[:flon_messages]
        .select(:exid)
        .where(status: 'created')
        .order_by(:ctime)
        .distinct
        .all
        .collect { |r| r[:exid] }
    end

    def load_execution(exid)

      e = @db[:flon_executions]
        .select(:id, :content)
        .where(status: 'active', exid: exid)
        .first

      ex =
        if e
          ex =
            from_json(e[:content]) ||
            fail("couldn't parse execution (db id #{e[:id]})")
          ex['id'] =
            e[:id]
          ex
        else
          ex = {
            'exid' => exid,
            'nodes' => {},
            'errors' => [],
            'counters' => { 'sub' => 0, 'fun' => -1 }
          }
          ex['id'] = @db[:flon_executions]
            .insert(
              exid: exid,
              content: to_blob(ex),
              status: 'active',
              ctime: Time.now,
              mtime: Time.now)
          ex
        end

      ex
    end

    def fetch_messages(exid)

      @db.transaction do

        ms = @db[:flon_messages]
          .select(:id, :content)
          .where(status: 'created', exid: exid)
          .order_by(:id)
          .map { |m| r = from_json(m[:content]) || {}; r['mid'] = m[:id]; r }

        @db[:flon_messages]
          .where(id: ms.collect { |m| m['mid'] })
          .update(status: 'consumed')

        ms
      end
    end

    def consume(messages)

      @db[:flon_messages]
        .where(id: messages.collect { |m| m['mid'] }.compact)
        .update(status: 'consumed', mtime: Time.now)
    end

    def load_timers

      @db[:flon_timers]
        .select(:id, :content)
        .where(status: 'created')
        .order_by(:id)
        .collect { |m| r = from_json(m[:content]) || {}; r['mid'] = m[:id]; r }
    end

    def put_messages(ms)

      return if ms.empty?

      n = Time.now

      @db[:flon_messages]
        .import(
          [ :exid, :point, :content, :status, :ctime, :mtime ],
          ms.map { |m| [ m['exid'], m['point'], to_blob(m), 'created', n, n ] })

      @unit.ping(ms.collect { |m| m['exid'] }.uniq)
    end

    def put_message(m)

      put_messages([ m ])
    end

    protected

    def connect

      uri = @unit.conf['sto_uri']

      uri = "jdbc:#{uri}" \
        if RUBY_PLATFORM.match(/java/) && uri.match(/\Asqlite:/)

      Sequel.connect(uri)
    end

    def to_blob(h)

      Sequel.blob(JSON.dump(h))
    end

    def from_json(s)

      JSON.parse(s) rescue nil
    end
  end
end

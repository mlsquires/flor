
module Flor

  class Executor

    attr_reader :unit
    attr_reader :execution
    attr_reader :hooks
    attr_reader :traps

    def initialize(unit, hooks, traps, execution)

      @unit = unit
      @execution = execution

      @hooks = hooks # raw hooks if any, fresh from the loader
      @traps = traps # array of Trap instances
    end

    def conf; @unit.conf; end
    def exid; @execution['exid']; end

    def node(msg_or_nid, node_instance=false)

      return nil unless msg_or_nid

      nid = msg_or_nid
      msg = msg_or_nid
      #
      if nid.is_a?(String)
        msg = nil
      else
        nid = msg['nid']
      end

      n = @execution['nodes'][nid]

      return nil unless n
      node_instance ? Flor::Node.new(self, n, msg) : n
    end

    def counter(key)

      @execution['counters'][key.to_s] || -1
    end

    def counter_add(key, count)

      k = key.to_s

      @execution['counters'][k] ||= 0
      @execution['counters'][k] += count
    end

    def counter_next(key)

      counter_add(key, 1)
    end

    def trigger_trap(trap, message)

      del, msgs = trap.trigger(self, message)
      @traps.delete(trap) if del

      msgs
    end

    def trigger_hook(hook, message)

      hook.notify(self, message)
    end

    def trigger_block(block, opts, message)

      r =
        if block.arity == 1
          block.call(message)
        elsif block.arity == 2
          block.call(message, opts)
        else
          block.call(self, message, opts)
        end

      r.is_a?(Array) && r.all? { |e| e.is_a?(Hash) } ? r : []
        # be lenient with block hooks, help them return an array
    end

    # Given a nid, returns a copy of all the var the node sees
    #
    def vars(nid, vs={})

      n = node(nid); return vs unless n

      (n['vars'] || {})
        .each { |k, v| vs[k] = Flor.dup(v) unless vs.has_key?(k) }

      if @unit.loader && n['parent'] == nil && n['vdomain'] != false

        @unit.loader.variables(n['vdomain'] || Flor.domain(@exid))
          .each { |k, v| vs[k] = Flor.dup(v) unless vs.has_key?(k) }
      end

      if cn = n['cnid']; vars(cn, vs); end
      if pa = n['parent']; vars(pa, vs); end

      vs
    end

    def traps_and_hooks

      @htraps = nil if @htraps && @htraps.size != @traps.size

      @htraps ||= @traps.collect(&:to_hook)
      @hhooks ||= @hooks.collect(&:to_hook)

      @htraps + @hhooks
    end

    protected

    def make_node(message)

      nid = message['nid']

      now = Flor.tstamp

      node = {
        'nid' => nid,
        'parent' => message['from'],
        'payload' => message['payload'],
        'status' => [ { 'status' => nil, 'point' => 'execute', 'ctime' => now } ],
        'ctime' => now,
        'mtime' => now }

      %w[ vars vdomain cnid dbg ].each do |k|
        v = message[k]
        node[k] = v if v != nil
      end
        #
        # vars: variables
        # vdomain: variable domain (used in conjuction with the loader)
        # cnid: closure nid
        # dbg: used to debug messages (useful @node['dbg'] when 'receive')

      @execution['nodes'][nid] = node
    end

    def determine_heat(message)

      nid = message['nid']

      return unless nid

      node =
        message['point'] == 'execute' ?
        make_node(message) :
        @execution['nodes'][nid]

      return unless node

      return if node['heat']

      n = Flor::Node.new(self, node, message)

      mt = message['tree']
      mt = [ 'noeval', [ 0 ], mt[2] ] \
        if mt[0] == '_' && Flor.is_array_of_trees?(mt[1])

      nt = n.lookup_tree(nid)

      node['tree'] = mt if mt && (mt != nt)
      tree = node['tree'] || nt

      t0 = tree[0]
      t0 = (t0.is_a?(Array) && t0[0] == '_dqs') ? n.expand(t0[1]) : t0

      node['heat0'] = tree[0]
      node['heat'] = heat = n.deref(t0)
      node['heap'] = heap = n.reheap(tree, heat)

      # "exceptions"

# TODO could those two ifs go upstream (top of this method)
#      and thus become smaller
#
      if message['accept_symbol'] && node['heat'] == nil
        #
        # tag: et al

        tree = node['tree'] = message['tree'] = [ '_dqs', tree[0], tree[2] ]

        node['heat0'] = tree[0]
        node['heat'] = heat = n.deref(tree[0])
        node['heap'] = heap = n.reheap(tree, heat)

      elsif heap == 'task' && heat[0] == '_task'
        #
        # rewrite `alpha` into `task alpha`

        l = message['tree'][2]

        message['otree'] = Flor.dup(message['tree'])

        message['tree'][0] =
          'task'
        message['tree'][1].unshift(
          [ '_att', [ [ '_sqs', heat[1]['task'], l ] ], l ])
      end
    end

    def execute(message)

      apply(@execution['nodes'][message['nid']], message)
    end

    def apply(node, message)

      heap =
        if node['heat']
          node['heap']
        else
          node['failure'] ? '_err' : nil
        end

      return error_reply(
        node, message, "don't know how to apply #{node['heat0'].inspect}"
      ) if heap == nil

      heac = Flor::Procedure[heap]
      fail NameError.new("unknown procedure #{heap.inspect}") unless heac

      head = heac.new(self, node, message)

      return [ head.rewrite ] if head.is_a?(Flor::Macro)

      pt = message['point']
      pt = "do_#{pt}" if pt == 'receive' || pt == 'cancel'

      pre_execute(head)

      head.send(pt)
    end

    def pre_execute(head)

      return unless head.message['point'] == 'execute'

      nid = head.nid

      head.pre_execute
      pnode = @execution['nodes'][head.parent]
      cnodes = pnode && (pnode['cnodes'] ||= [])
      cnodes << nid if cnodes && ( ! cnodes.include?(nid))
    end

    def receive(message)

      messages = leave_node(message)

      nid = message['nid']

      return messages + toc_messages(message) unless nid
        # 'terminated' or 'ceased'

      node = @execution['nodes'][nid]

      return messages unless node
        # node gone...

      messages + apply(node, message)
    end

    def leave_node(message)

      fnid = message['from']; return [] unless fnid
      fnode = @execution['nodes'][fnid]; return [] unless fnode

      remove_node(message, fnode)

      leave_tags(message, fnode) # returns messages
    end

    def remove_node(message, node)

      Flor::Procedure.new(self, node, message).end

      return if (node['closures'] || []).any?
        # don't remove the node if it's a closure for some other nodes

      nid = node['nid']

      return if nid == '0'
        # don't remove if it's the "root" node

      @unit.archive_node(message['exid'], node)
        # archiving is only active during testing

      @execution['nodes'].delete(nid)
    end

    def leave_tags(message, node)

      ts = node['tags']; return [] unless ts && ts.any?

      [
        { 'point' => 'left',
          'tags' => ts,
          'exid' => exid,
          'nid' => node['nid'],
          'payload' => message['payload'] }
      ]
    end

    def toc_messages(message)

      m = message.select { |k, v| %w[ exid nid from payload ].include?(k) }
      m['sm'] = message['m']
      m['point'] = message['from'] == '0' ? 'terminated' : 'ceased'

      [ m ]
    end

    def error_reply(node, message, err)

      m = message
        .select { |k, v| %w[ sm exid nid from payload tree ].include?(k) }

      m['point'] = 'failed'
      m['fpoint'] = message['point']
      m['error'] = Flor.to_error(err)

      @unit.logger.log_err(self, m, flag: true)
      #Flor.print_detail_msg(self, m, flag: true) if @unit.conf['log_err']

      #if m['error']['msg'].match(/\AToo many open files in system/)
      #  puts "=" * 80 + ' ...'
      #  system(`lsof #{Process.pid}`)
      #  puts "=" * 80 + ' .'
      #end
        #
        # can't seem to provoke that error, so keeping the trap
        # around but commented out...

      [ m ]
    end

    def task(message)

      return error_reply(
        node(message['nid']),
        message,
        "don't know how to apply #{message['tasker'].inspect}"
      ) if message['routed'] == false

      @execution['tasks'][message['nid']] =
        { 'tasker' => message['tasker'], 'name' => message['taskname'] }
          #
          # FIXME is it in use???

      @unit.ganger.task(self, message)
    end
    alias detask task

    def return(message)

      @execution['tasks'].delete(message['nid'])
        #
        # FIXME is it in use???

      [
        { 'point' => 'receive',
          'exid' => message['exid'],
          'nid' => message['nid'],
          'payload' => message['payload'],
          'tasker' => message['tasker'] }
      ]
    end

    def cancel(message)

      if n = @execution['nodes'][message['nid']]
        apply(n, message)
      else
        [] # nothing, node gone
      end
    end

    def process(message)

      begin

        message['m'] = counter_next('msgs') # number messages
        message['pr'] = counter('runs') # "processing run"

        determine_heat(message)

        ms = []
        ms += @unit.notify(self, message) # pre

        ms += self.send(message['point'], message)

        message['payload'] = message.delete('pld') if message.has_key?('pld')
        message['consumed'] = Flor.tstamp

        ms += @unit.notify(self, message) # post

        ms.each { |m| m['er'] = counter('runs') } # "emitting run"

      rescue => e
        error_reply(nil, message, e)
      rescue ScriptError => se
        error_reply(nil, message, se)
      end
    end

    def trap(message)

      exid = message['exid']
      nid = message['nid']
      trap = message['trap']

      nd = node(nid)
      nd['exid'] = exid

      @traps << @unit.trap(nd, trap)

      []
    end

    def entered(message); []; end
    def left(message); []; end

    def ceased(message); []; end

    def terminated(message)

      message['vars'] = @execution['nodes']['0']['vars']
        # especially useful for debugging

      []
    end


    def failed(message)

      n = node(message['nid'])

      fail RuntimeError.new(
        "node #{message['nid']} is gone, cannot flag it as failed"
      ) unless n

#begin
      n['failure'] = Flor.dup(message)
#rescue; pp message; exit 0; end

      oep = lookup_on_error_parent(message)
      return oep.trigger_on_error if oep

      @unit.logger.log_err(self, message)

      []
    end

    def signal(message); []; end

    def lookup_on_error_parent(message)

      nd = Flor::Node.new(self, nil, message).on_error_parent
      nd ? nd.to_procedure : nil
    end
  end
end


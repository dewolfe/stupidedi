module Stupidedi
  module Builder

    module Navigation

      # @return [Array<InstructionTable>]
      def successors
        @active.map{|a| a.node.instructions }
      end

      def deterministic?
        @active.length == 1
      end

      # Is this the first segment?
      def first?
        value = @active.head.node.zipper

        until value.root?
          return false unless value.first?
          value = value.up
        end

        return true
      end

      # Is this the last segment?
      def last?
        value = @active.head.node.zipper

        until value.root?
          return false unless value.last?
          value = value.up
        end

        return true
      end

      # @return [Either<Zipper::AbstractCursor<Values::AbstractVal>>]
      def zipper
        if deterministic?
          Either.success(@active.head.node.zipper)
        else
          Either.failure("non-deterministic state")
        end
      end

      # @group Navigating the Tree
      #########################################################################

      # @return [Either<Zipper::AbstractCursor<Values::SegmentVal>>]
      def segment
        zipper.flatmap do |z|
          if z.node.segment?
            Either.success(z)
          else
            Either.failure("not a segment")
          end
        end
      end

      # @return [Either<Zipper::AbstractCUrsor<Values::AbstractElementVal>>]
      def element(m, n = nil, o = nil)
        segment.flatmap do |s|
          designator = s.node.id.to_s
          definition = s.node.definition
          length     = definition.element_uses.length

          unless m >= 1
            raise ArgumentError,
              "argument must be positive"
          end

          unless m <= length
            raise ArgumentError,
              "#{designator} segment has only #{length} elements"
          end

          designator << "%02d" % m
          value       = s.child(m - 1)

          if n.nil?
            return Either.success(value)
          elsif value.node.repeated?
            unless n >= 1
              raise ArgumentError,
                "argument must be positive"
            end

            unless value.node.children.defined_at?(n - 1)
              return Either.failure("#{designator} occurs only #{value.node.children.length} times")
            end

            value = value.child(n - 1)
            n, o  = o, nil

            return Either.success(value) if n.nil?
          end

          unless value.node.composite?
            raise ArgumentError,
              "#{designator} is a simple element"
          end

          unless o.nil?
            raise ArgumentError,
              "#{designator} is a non-repeatable composite element"
          end

          unless n >= 1
            raise ArgumentError,
              "argument must be positive"
          end

          length = definition.element_uses.at(m - 1).definition.component_uses.length
          unless n <= length
            raise ArgumentError,
              "#{designator} has only #{length} components"
          end

          Either.success(value.child.at(n - 1))
        end
      end

      # @return [Either<StateMachine>]
      def first
        active = roots.map do |zipper|
          state = zipper
          value = zipper.node.zipper

          until value.node.segment? or value.leaf?
            value = value.down
            state = state.down
          end

          if value.leaf?
            return Either.failure("no segments")
          end

          unless value.eql?(state.node.zipper)
            state = state.replace(state.node.copy(:zipper => value))
          end

          state
        end

        Either.success(StateMachine.new(@config, active))
      end

      # @return [Either<StateMachine>]
      def last
        active = roots.map do |zipper|
          state = zipper
          value = zipper.node.zipper

          until value.node.segment? or value.leaf?
            value = value.down.last
            state = state.down.last
          end

          if value.leaf?
            return Either.failure("no segments")
          end

          unless value.eql?(state.node.zipper)
            state = state.replace(state.node.copy(:zipper => value))
          end

          state
        end

        Either.success(StateMachine.new(@config, active))
      end

      # @return [StateMachine]
      def next(count = 1)
        active = @active.map do |zipper|
          state = zipper
          value = zipper.node.zipper

          count.times do
            while not value.root? and value.last?
              value = value.up
              state = state.up
            end

            if value.root?
              return Either.failure("cannot move to next after last segment")
            end

            value = value.next
            state = state.next

            until value.node.segment?
              value = value.down
              state = state.down
            end
          end

          unless value.eql?(state.node.zipper)
            state = state.replace(state.node.copy(:zipper => value))
          end

          state
        end

        Either.success(StateMachine.new(@config, active))
      end

      # @return [Either<StateMachine>]
      def prev(count = 1)
        active = @active.map do |zipper|
          state = zipper
          value = zipper.node.zipper

          count.times do
            while not value.root? and value.first?
              value = value.up
              state = state.up
            end

            if value.root?
              return Either.failure("cannot move to prev before first segment")
            end

            state = state.prev
            value = value.prev

            until value.node.segment?
              value = value.down.last
              state = state.down.last
            end
          end

          unless value.eql?(state.node.zipper)
            state = state.replace(state.node.copy(:zipper => value))
          end

          state
        end

        Either.success(StateMachine.new(@config, active))
      end

      # @return [Either<StateMachine>]
      def find(id, *elements)
        reachable = false
        matches   = []

        @active.each do |zipper|
          segment_tok  = mksegment_tok(zipper.node.segment_dict, id, elements)
          instructions = zipper.node.instructions.matches(segment_tok, true)
          matched      = false
          reachable  ||= !instructions.empty?

          instructions.each do |op|
            break if matched

            state = zipper
            value = zipper.node.zipper

            op.pop_count.times do
              value = value.up
              state = state.up
            end

            # The state we're searching for will have an ancestor state
            # with this instruction table
            target = zipper.node.instructions.pop(op.pop_count).drop(op.drop_count)

            until state.last?
              state = state.next
              value = value.next

              if target.eql?(state.node.instructions)
                # Found the ancestor state. Often the segment belongs to this
                # state, but some states correspond to values which indirectly
                # contain segments (eg, TransactionSetVal does not have child
                # segments, it has TableVals which either contain a SegmentVal
                # or a LoopVal that contains a SegmentVal)
                _value = value
                _state = state

                until _value.node.segment?
                  _value = _value.down
                  _state = _state.down
                end

                if op.segment_use.nil? or op.segment_use.eql?(_value.node.usage)
                  next if filter?(segment_tok, _value.node)

                  unless _value.eql?(_state.node.zipper)
                    _state = _state.replace(_state.node.copy(:zipper => _value))
                  end

                  matches << _state
                  matched  = true
                  break
                end
              elsif target.length > state.node.instructions.length
                # The ancestor state isn't one of the rightward siblings, since
                # the length of instruction tables is non-increasing as we move
                # rightward
                break
              end
            end
          end
        end

        if not reachable
          raise Exceptions::ParseError,
            "#{id} segment cannot be reached from the current state"
        elsif matches.empty?
          Either.failure("#{id} segment does not occur")
        else
          Either.success(StateMachine.new(@config, matches))
        end
      end

    private

      def filter?(segment_tok, segment_val)
        segment_tok.element_toks.zip(segment_val.children) do |e_tok, e_val|
          if e_tok.simple?
            return true unless e_tok.blank? or e_val == e_tok.value
          elsif e_tok.composite?
            e_tok.component_toks.zip(e_val.children) do |c_tok, c_val|
              return true unless c_tok.blank? or c_val == c_tok.value
            end
          else
            raise Exceptions::ParseError,
              "only simple and component elements can be filtered"
          end
        end
      end

      # @return [Array<Zipper::AbstractCursor>]
      def roots
        @active.map do |zipper|
          state = zipper
          value = zipper.node.zipper

          zipper.depth.times do
            value = value.up
            state = state.up
          end

          unless value.eql?(state.node.zipper)
            state = state.replace(state.node.copy(:zipper => value))
          end

          state
        end
      end

      def xx(label, value, state)
      # puts label
      # puts " ~v: #{state.node.zipper.object_id} #{state.node.zipper.class.name.split('::').last}"
      # puts "  v: #{value.object_id} #{value.class.name.split('::').last}"
      # puts "     #{value.node.inspect}"
      # puts "  s: #{state.object_id} #{state.class.name.split('::').last}"
      # puts "     #{state.node.inspect}"
      end

    end

  end
end
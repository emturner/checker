(*
Utku: Lifecycle of liquidation slices.

1. When a 'liquidation_slice' is created from a burrow, it is
   added to the 'queued_slices' queue. This is backed by an AVL
   tree.

   Every 'liquidation_slice' has pointers to the older and younger
   slice for that burrow. This forms a double-linked list of slices
   overlaying the AVL tree.

   Every burrow has pointers to the first and the last element of
   that linked list, so adding/popping elements both  from the front
   and the back is efficient.

2. When checker is touched, and there is no existing auction
   going on, a prefix of the 'queued_slices' is split, and inserted
   as 'current_auction' alongside with the current timestamp. This
   process is efficient because of the AVL tree.

   When the prefix returned does not have as much tez as we
   want, this means that the next liquidation_slice in 'queued_slices'
   needs to be split. We can do this by popping the first item if exists,
   which as an invariant has more tez than we need, and splitting
   it into two slices, appending the first slice to the end of
   'current_auction', and the second one to back to the front of
   'queued_slices'. If there is no more slices, we still start the
   auction.

   While doing this, we also need to make sure that the pointers on
   liquidation slices are still correct.

3. Then an auction starts:

   > If there are any lots waiting to be auctioned, Checker starts an open,
   > ascending bid auction. There is a reserve price set at tz_t which declines
   > exponentially over time as long as no bid as been placed. Once a bid
   > is placed, the auction continues. Every bid needs to improve over the
   > previous bid by at least 0.33 cNp and adds the longer of 20 blocks or
   > 20 minutes, to the time before the auction expires.

   All bids can be claimed, unless they are the winning bid of the current
   or any of the past auctions.

   When an auction expires, the current auction is both moved to
   'completed_auctions' FIFO queue. This FIFO queue is implemented as a doubly
   linked list at tree roots.

4. When 'touch_liquidation_slice' is called the slice is checked if it belongs
   to a completed auction or not. This can be checked via the 'find_root'
   function of AVL trees. If we end up in 'queued_slices' or 'curent_auction',
   it is not complete, if not, it means that we're in 'completed_auctions'.

   If the slice is completed, then the burrows outstanding kit balance is
   adjusted and the leaf is deleted from the tree. If it was the last remaining
   slice of the relevant auction (in other words, if the auction's tree becomes
   empty after the removal), the auctions is popped from the 'completed_auctions'
   linked list.

5. When checker is touched, it fetches the oldest auction from `completed_auctions`
   queue, and processes a few of oldest liquidations. This is to clean-up the slices
   that haven't been claimed for some reason.

6. When the winner of an auction tries to claim the result, we check if its auction
   has no liquidation_slice's left. If all the slices are already touched, this
   means that the tree is already popped out of the completed_auctions list. In
   this case, we transfer the result to the callee, and remove the auction alltogether.
*)

open LiquidationAuctionPrimitiveTypes
open Mem
open Ratio
open FixedPoint
open Kit
open Avl
open Constants
open Common
open Tickets
open LiquidationAuctionTypes
open Error

(* When burrows send a liquidation_slice, they get a pointer into a tree leaf.
 * Initially that node belongs to 'queued_slices' tree, but this can change over time
 * when we start auctions.
*)
let liquidation_auction_send_to_auction
  (auctions: liquidation_auctions) (contents: liquidation_slice_contents)
  : liquidation_auctions =
  if avl_height auctions.avl_storage auctions.queued_slices
     >= max_liquidation_queue_height then
    (Ligo.failwith error_LiquidationQueueTooLong : liquidation_auctions)
  else
    let old_burrow_slices =  Ligo.Big_map.find_opt contents.burrow auctions.burrow_slices in

    let slice = {
           contents = contents;
           older = (
             match old_burrow_slices with
             | None -> (None : leaf_ptr option)
             | Some i -> Some i.youngest_slice
           );
           younger = (None: leaf_ptr option);
        } in

    let (new_storage, ret) =
      avl_push auctions.avl_storage auctions.queued_slices slice Left in

    (* Fixup the previous youngest pointer since the newly added slice
     * is even younger.
     *)
    let new_storage, new_burrow_slices = (
      match old_burrow_slices with
      | None -> (new_storage, { oldest_slice = ret; youngest_slice = ret; })
      | Some old_slices ->
        ( mem_update
            new_storage
            (ptr_of_leaf_ptr old_slices.youngest_slice)
            (fun (older: node) ->
               let older = node_leaf older in
               Leaf { older with value = { older.value with younger = Some ret; }; }
            )
        , { old_slices with youngest_slice = ret }
        )
    ) in

    { auctions with
      avl_storage = new_storage;
      burrow_slices =
        Ligo.Big_map.add
          contents.burrow
          new_burrow_slices
          auctions.burrow_slices;
    }

(** Split a liquidation slice into two. We also have to split the
  * min_kit_for_unwarranted so that we can evaluate the two auctions separately
  * (and see if the liquidation was warranted, retroactively). Perhaps a bit
  * harshly, for both slices we round up. NOTE: Alternatively, we can calculate
  * min_kit_for_unwarranted_1 and then calculate min_kit_for_unwarranted_2 =
  * min_kit_for_unwarranted - min_kit_for_unwarranted_1. *)
let split_liquidation_slice (amnt: Ligo.tez) (slice: liquidation_slice) : (liquidation_slice * liquidation_slice) =
  assert (amnt > Ligo.tez_from_literal "0mutez");
  assert (amnt < slice.contents.tez);
  (* general *)
  let min_kit_for_unwarranted = kit_to_mukit_int slice.contents.min_kit_for_unwarranted in
  let slice_tez = tez_to_mutez slice.contents.tez in
  (* left slice *)
  let ltez = amnt in
  let lkit =
    kit_of_fraction_ceil
      (Ligo.mul_int_int min_kit_for_unwarranted (tez_to_mutez ltez))
      (Ligo.mul_int_int kit_scaling_factor_int slice_tez)
  in
  (* right slice *)
  let rtez = Ligo.sub_tez_tez slice.contents.tez amnt in
  let rkit =
    kit_of_fraction_ceil
      (Ligo.mul_int_int min_kit_for_unwarranted (tez_to_mutez rtez))
      (Ligo.mul_int_int kit_scaling_factor_int slice_tez)
  in
  (* FIXME: We also need to fixup the pointers here *)
  ( { slice with
      contents = { slice.contents with
                   tez = ltez;
                   min_kit_for_unwarranted = lkit;
                 }
    },
    { slice with
      contents = { slice.contents with
                   tez = rtez;
                   min_kit_for_unwarranted = rkit;
                 }
    }
  )

let take_with_splitting (storage: mem) (queued_slices: avl_ptr) (split_threshold: Ligo.tez) =
  let (storage, new_auction) = avl_take storage queued_slices split_threshold (None: auction_outcome option) in
  let queued_amount = avl_tez storage new_auction in
  if queued_amount < split_threshold
  then
    (* split next thing *)
    let (storage, next) = avl_pop_front storage queued_slices in
    match next with
    | Some slice ->
      let (part1, part2) = split_liquidation_slice (Ligo.sub_tez_tez split_threshold queued_amount) slice in
      let (storage, _) = avl_push storage queued_slices part2 Right in
      let (storage, _) = avl_push storage new_auction part1 Left in
      (storage, new_auction)
    | None ->
      (storage, new_auction)
  else
    (storage, new_auction)

let start_liquidation_auction_if_possible
    (start_price: ratio) (auctions: liquidation_auctions): liquidation_auctions =
  match auctions.current_auction with
  | Some _ -> auctions
  | None ->
    let queued_amount = avl_tez auctions.avl_storage auctions.queued_slices in
    let split_threshold =
      (* split_threshold = max (max_lot_size, FLOOR(queued_amount * min_lot_auction_queue_fraction)) *)
      let { num = num_qf; den = den_qf; } = min_lot_auction_queue_fraction in
      max_tez
        max_lot_size
        (fraction_to_tez_floor
           (Ligo.mul_int_int (tez_to_mutez queued_amount) num_qf)
           (Ligo.mul_int_int (Ligo.int_from_literal "1_000_000") den_qf)
        ) in
    let (storage, new_auction) =
      take_with_splitting
        auctions.avl_storage
        auctions.queued_slices
        split_threshold in
    let current_auction =
      if avl_is_empty storage new_auction
      then (None: current_liquidation_auction option)
      else
        let start_value =
          let { num = num_sp; den = den_sp; } = start_price in
          kit_of_fraction_ceil
            (Ligo.mul_int_int (tez_to_mutez (avl_tez storage new_auction)) num_sp)
            (Ligo.mul_int_int (Ligo.int_from_literal "1_000_000") den_sp)
        in
        Some
          { contents = new_auction;
            state = Descending (start_value, !Ligo.Tezos.now); } in
    { auctions with
      avl_storage = storage;
      current_auction = current_auction;
    }

(** Compute the current threshold for a bid to be accepted. For a descending
  * auction this amounts to the reserve price (which is exponentially
  * dropping). For a descending auction we should improve upon the last bid
  * a fixed factor. *)
let liquidation_auction_current_auction_minimum_bid (auction: current_liquidation_auction) : kit =
  match auction.state with
  | Descending params ->
    let (start_value, start_time) = params in
    let auction_decay_rate = fixedpoint_of_ratio_ceil auction_decay_rate in
    let decay =
      match Ligo.is_nat (Ligo.sub_timestamp_timestamp !Ligo.Tezos.now start_time) with
      | None -> (failwith "TODO: is this possible?" : fixedpoint) (* TODO *)
      | Some secs -> fixedpoint_pow (fixedpoint_sub fixedpoint_one auction_decay_rate) secs in
    kit_scale start_value decay
  | Ascending params ->
    let (leading_bid, _timestamp, _level) = params in
    let bid_improvement_factor = fixedpoint_of_ratio_floor bid_improvement_factor in
    kit_scale leading_bid.kit (fixedpoint_add fixedpoint_one bid_improvement_factor)

(** Check if an auction is complete. A descending auction declines
  * exponentially over time, so it is effectively never complete (George: I
  * guess when it reaches zero it is, but I'd expect someone to buy before
  * that?). If the auction is ascending, then every bid adds the longer of 20
  * minutes or 20 blocks to the time before the auction expires. *)
let is_liquidation_auction_complete
    (auction_state: liquidation_auction_state) : bid option =
  match auction_state with
  | Descending _ ->
    (None: bid option)
  | Ascending params ->
    let (b, t, h) = params in
    if Ligo.sub_timestamp_timestamp !Ligo.Tezos.now t
       > max_bid_interval_in_seconds
    && Ligo.gt_int_int
         (Ligo.sub_nat_nat !Ligo.Tezos.level h)
         (Ligo.int max_bid_interval_in_blocks)
    then Some b
    else (None: bid option)

let complete_liquidation_auction_if_possible
    (auctions: liquidation_auctions): liquidation_auctions =
  match auctions.current_auction with
  | None -> auctions
  | Some curr -> begin
      match is_liquidation_auction_complete curr.state with
      | None -> auctions
      | Some winning_bid ->
        let (storage, completed_auctions) = match auctions.completed_auctions with
          | None ->
            let outcome =
              { winning_bid = winning_bid;
                sold_tez=avl_tez auctions.avl_storage curr.contents;
                younger_auction=(None: liquidation_auction_id option);
                older_auction=(None: liquidation_auction_id option);
              } in
            let storage =
              avl_modify_root_data
                auctions.avl_storage
                curr.contents
                (fun (prev: auction_outcome option) ->
                   assert (Option.is_none prev);
                   Some outcome) in
            (storage, {youngest=curr.contents; oldest=curr.contents})
          | Some params ->
            let {youngest=youngest; oldest=oldest} = params in
            let outcome =
              { winning_bid = winning_bid;
                sold_tez=avl_tez auctions.avl_storage curr.contents;
                younger_auction=Some youngest;
                older_auction=(None: liquidation_auction_id option);
              } in
            let storage =
              avl_modify_root_data
                auctions.avl_storage
                curr.contents
                (fun (prev: auction_outcome option) ->
                   assert (Option.is_none prev);
                   Some outcome) in
            let storage =
              avl_modify_root_data
                storage
                youngest
                (fun (prev: auction_outcome option) ->
                   match prev with
                   | None -> (failwith "completed auction without outcome" : auction_outcome option)
                   | Some xs -> Some ({xs with younger_auction=Some curr.contents})
                ) in
            (storage, {youngest=curr.contents; oldest=oldest; }) in
        { auctions with
          avl_storage = storage;
          current_auction=(None: current_liquidation_auction option);
          completed_auctions=Some completed_auctions;
        }
    end

(** Place a bid in the current auction. Fail if the bid is too low (must be at
  * least as much as the liquidation_auction_current_auction_minimum_bid. *)
let place_liquidation_auction_bid (auction: current_liquidation_auction) (bid: bid) : (current_liquidation_auction * liquidation_auction_bid) =
  if bid.kit >= liquidation_auction_current_auction_minimum_bid auction
  then
    ( { auction with state = Ascending (bid, !Ligo.Tezos.now, !Ligo.Tezos.level); },
      { auction_id = auction.contents; bid = bid; }
    )
  else (Ligo.failwith error_BidTooLow : current_liquidation_auction * liquidation_auction_bid)

let liquidation_auction_get_current_auction (auctions: liquidation_auctions) : current_liquidation_auction =
  match auctions.current_auction with
  | None -> (Ligo.failwith error_NoOpenAuction : current_liquidation_auction)
  | Some curr -> curr

let is_leading_current_liquidation_auction
    (auctions: liquidation_auctions) (bid_details: liquidation_auction_bid): bool =
  match auctions.current_auction with
  | Some auction ->
    if ptr_of_avl_ptr auction.contents = ptr_of_avl_ptr bid_details.auction_id
    then
      (match auction.state with
       | Ascending params ->
         let (bid, _timestamp, _level) = params in
         bid_eq bid bid_details.bid
       | Descending _ -> false)
    else false
  | None -> false

(* removes the slice from liquidation_auctions, fixing up the necessary pointers.
 * returns the contents of the removed slice, the tree root the slice belonged to, and the updated auctions
 *)
let pop_slice (auctions: liquidation_auctions) (leaf_ptr: leaf_ptr): liquidation_slice_contents * avl_ptr * liquidation_auctions =
  let avl_storage = auctions.avl_storage in

  (* pop the leaf from the storage *)
  let leaf = avl_read_leaf avl_storage leaf_ptr in
  let avl_storage, root_ptr = avl_del avl_storage leaf_ptr in

  (* fixup burrow_slices *)
  let burrow_slices = match Ligo.Big_map.find_opt leaf.contents.burrow auctions.burrow_slices with
      | None -> (failwith "invariant violation: got a slice which is not present on burrow_slices": burrow_liquidation_slices)
      | Some s -> s in
  let burrow_slices =
    match leaf.younger with
    | None -> begin
      match leaf.older with
      | None -> (* leaf *) (None: burrow_liquidation_slices option)
      | Some older -> (* .. - older - leaf *) Some { burrow_slices with youngest_slice = older }
      end
    | Some younger -> begin
      match leaf.older with
      | None -> (* leaf - younger - ... *) Some { burrow_slices with oldest_slice = younger }
      | Some _ -> (* ... - leaf - ... *) Some burrow_slices
      end in

  (* fixup older and younger pointers *)
  let avl_storage = (
    match leaf.younger with
    | None -> avl_storage
    | Some younger_ptr ->
        avl_update_leaf
          avl_storage
          younger_ptr
          (fun (younger: liquidation_slice) ->
             assert (younger.older = Some leaf_ptr);
             { younger with older = leaf.older }
          )
  ) in
  let avl_storage = (
    match leaf.older with
    | None -> avl_storage
    | Some older_ptr ->
        avl_update_leaf
          avl_storage
          older_ptr
          (fun (older: liquidation_slice) ->
             assert (older.younger = Some leaf_ptr);
             { older with younger = leaf.younger }
          )
  ) in

  (* return *)
  ( leaf.contents
  , root_ptr
  , { auctions with
      avl_storage = avl_storage;
      burrow_slices = Ligo.Big_map.update leaf.contents.burrow burrow_slices auctions.burrow_slices;
    }
  )

let liquidation_auctions_cancel_slice (auctions: liquidation_auctions) (leaf_ptr: leaf_ptr) : liquidation_slice_contents * liquidation_auctions =
  let (contents, root, auctions) = pop_slice auctions leaf_ptr in
  if ptr_of_avl_ptr root <> ptr_of_avl_ptr auctions.queued_slices
  then (Ligo.failwith error_UnwarrantedCancellation : liquidation_slice_contents * liquidation_auctions)
  else (contents, auctions)

let completed_liquidation_auction_won_by
    (avl_storage: mem) (bid_details: liquidation_auction_bid): auction_outcome option =
  match avl_root_data avl_storage bid_details.auction_id with
  | Some outcome ->
    if bid_eq outcome.winning_bid bid_details.bid
    then Some outcome
    else (None: auction_outcome option)
  | None -> (None: auction_outcome option)

(* If successful, it consumes the ticket. *)
let reclaim_liquidation_auction_bid (auctions: liquidation_auctions) (bid_details: liquidation_auction_bid) : kit =
  if is_leading_current_liquidation_auction auctions bid_details
  then (Ligo.failwith error_CannotReclaimLeadingBid : kit)
  else
    match completed_liquidation_auction_won_by auctions.avl_storage bid_details with
    | Some _ -> (Ligo.failwith error_CannotReclaimWinningBid : kit)
    | None -> bid_details.bid.kit

(* Removes the auction from completed lots list, while preserving the auction itself. *)
let liquidation_auction_pop_completed_auction (auctions: liquidation_auctions) (tree: avl_ptr) : liquidation_auctions =
  let storage = auctions.avl_storage in

  let outcome = match avl_root_data storage tree with
    | None -> (failwith "auction is not completed" : auction_outcome)
    | Some r -> r in
  let completed_auctions = match auctions.completed_auctions with
    | None -> (failwith "invariant violation" : completed_liquidation_auctions)
    | Some r -> r in

  (* First, fixup the completed auctions if we're dropping the
   * youngest or the oldest lot. *)
  let completed_auctions =
    match outcome.younger_auction with
    | None -> begin
        match outcome.older_auction with
        | None ->
          assert (completed_auctions.youngest = tree);
          assert (completed_auctions.oldest = tree);
          (None: completed_liquidation_auctions option)
        | Some older ->
          assert (completed_auctions.youngest = tree);
          assert (completed_auctions.oldest <> tree);
          Some {completed_auctions with youngest = older }
      end
    | Some younger -> begin
        match outcome.older_auction with
        | None ->
          assert (completed_auctions.youngest <> tree);
          assert (completed_auctions.oldest = tree);
          Some {completed_auctions with oldest = younger }
        | Some _older ->
          assert (completed_auctions.youngest <> tree);
          assert (completed_auctions.oldest <> tree);
          Some completed_auctions
      end in

  (* Then, fixup the pointers within the list.*)
  let storage =
    match outcome.younger_auction with
    | None -> storage
    | Some younger ->
      avl_modify_root_data storage younger (fun (i: auction_outcome option) ->
          let i = match i with
            | None -> (failwith "invariant violation: completed auction does not have outcome": auction_outcome)
            | Some i -> i in
          assert (i.older_auction = Some tree);
          Some {i with older_auction=outcome.older_auction}) in
  let storage =
    match outcome.older_auction with
    | None -> storage
    | Some older ->
      avl_modify_root_data storage older (fun (i: auction_outcome option) ->
          let i = match i with
            | None -> (failwith "invariant violation: completed auction does not have outcome": auction_outcome)
            | Some i -> i in
          assert (i.younger_auction = Some tree);
          Some {i with younger_auction=outcome.younger_auction}) in

  let storage = avl_modify_root_data storage tree (fun (_: auction_outcome option) ->
      Some { outcome with
             younger_auction = (None: liquidation_auction_id option);
             older_auction = (None: liquidation_auction_id option)}) in

  { auctions with
    completed_auctions = completed_auctions;
    avl_storage = storage
  }

let liquidation_auctions_pop_completed_slice (auctions: liquidation_auctions) (leaf_ptr: leaf_ptr) : liquidation_slice_contents * auction_outcome * liquidation_auctions =
  let (contents, root, auctions) = pop_slice auctions leaf_ptr in

  (* When the auction has no slices left, we pop it from the linked list
   * of lots. We do not delete the auction itself from the storage, since
   * we still want the winner to be able to claim its result. *)
  let auctions =
     if avl_is_empty auctions.avl_storage root
     then liquidation_auction_pop_completed_auction auctions root
     else auctions in
  let outcome =
     match avl_root_data auctions.avl_storage root with
     | None -> (Ligo.failwith error_NotACompletedSlice: auction_outcome)
     | Some outcome -> outcome in
  (contents, outcome, auctions)

(* If successful, it consumes the ticket. *)
let[@inline] reclaim_liquidation_auction_winning_bid (auctions: liquidation_auctions) (bid_details: liquidation_auction_bid) : (Ligo.tez * liquidation_auctions) =
  match completed_liquidation_auction_won_by auctions.avl_storage bid_details with
  | Some outcome ->
    (* A winning bid can only be claimed when all the liquidation slices
     * for that lot is cleaned. *)
    if not (avl_is_empty auctions.avl_storage bid_details.auction_id)
    then (Ligo.failwith error_NotAllSlicesClaimed : Ligo.tez * liquidation_auctions)
    else (
      (* When the winner reclaims their bid, we finally remove
         every reference to the auction. This is just to
         save storage, what's forbidding double-claiming
         is the ticket mechanism, not this.
      *)
      assert (outcome.younger_auction = None);
      assert (outcome.older_auction = None);
      let auctions =
        { auctions with
          avl_storage =
            avl_delete_empty_tree auctions.avl_storage bid_details.auction_id } in
      (outcome.sold_tez, auctions)
    )
  | None -> (Ligo.failwith error_NotAWinningBid : Ligo.tez * liquidation_auctions)

(*
 * - Cancel auction
 *
 * TODO: how to see current leading bid? FA2?
 * TODO: return kit to losing bidders
 * TODO: when liquidation result was "close", what happens after the tez is sold? Might we find that we didn't need to close it after all?
 *)

let liquidation_auction_oldest_completed_liquidation_slice (auctions: liquidation_auctions) : leaf_ptr option =
  match auctions.completed_auctions with
  | None -> (None: leaf_ptr option)
  | Some completed_auctions -> begin
      match avl_peek_front auctions.avl_storage completed_auctions.youngest with
      | None -> (failwith "invariant violation: empty auction in completed_auctions" : leaf_ptr option)
      | Some p ->
        let (leaf_ptr, _) = p in
        Some leaf_ptr
    end

let is_burrow_done_with_liquidations (auctions: liquidation_auctions) (burrow: Ligo.address) =
  match Ligo.Big_map.find_opt burrow auctions.burrow_slices with
  | None -> true
  | Some bs ->
    let root = avl_find_root auctions.avl_storage bs.oldest_slice in
    let outcome = avl_root_data auctions.avl_storage root in
    (match outcome with
     | None -> true
     | Some _ -> false)

(* BEGIN_OCAML *)

let liquidation_auction_current_auction_tez (auctions: liquidation_auctions) : Ligo.tez option =
  match auctions.current_auction with
  | None -> (None: Ligo.tez option)
  | Some auction -> Some (avl_tez auctions.avl_storage auction.contents)

(* Checks if some invariants of auctions structure holds. *)
let assert_liquidation_auction_invariants (auctions: liquidation_auctions) : unit =

  (* All AVL trees in the storage are valid. *)
  let mem = auctions.avl_storage in
  let roots = Ligo.Big_map.bindings mem.mem
              |> List.filter (fun (_, n) -> match n with | LiquidationAuctionPrimitiveTypes.Root _ -> true; | _ -> false)
              |> List.map (fun (p, _) -> AVLPtr p) in
  List.iter (assert_avl_invariants mem) roots;

  (* There are no dangling pointers in the storage. *)
  avl_assert_dangling_pointers mem roots;

  (* Completed_auctions linked list is correct. *)
  auctions.completed_auctions
  |> Option.iter (fun completed_auctions ->
      let rec go (curr: avl_ptr) (prev: avl_ptr option) =
        let curr_data = Option.get (avl_root_data mem curr) in
        assert (curr_data.younger_auction = prev);
        match curr_data.older_auction with
        | Some next -> go next (Some curr)
        | None ->  assert (curr = completed_auctions.oldest) in
      go (completed_auctions.youngest) None
    );

  (* TODO: Check if all dangling auctions are empty. *)

  ()
(* END_OCAML *)

(* ************************************************************************* *)
(*                                ????????                                   *)
(* ************************************************************************* *)

let[@inline] liquidation_auction_touch (auctions: liquidation_auctions) (price: ratio) : LigoOp.operation list * liquidation_auctions =
  assert (!Ligo.Tezos.self_address = auctions_public_address); (* ENSURE IT's CALLED IN THE RIGHT CONTEXT. *)
  let auctions = complete_liquidation_auction_if_possible auctions in
  let auctions = start_liquidation_auction_if_possible price auctions in
  (([]: LigoOp.operation list), auctions)

(* Looks up a burrow_id from state, and checks if the resulting burrow does
 * not have any completed liquidation slices that need to be claimed before
 * any operation. *)
let[@inline] ensure_no_unclaimed_slices (auctions: liquidation_auctions) (burrow_id: Ligo.address) : LigoOp.operation list * liquidation_auctions =
  assert (!Ligo.Tezos.self_address = auctions_public_address); (* ENSURE IT's CALLED IN THE RIGHT CONTEXT. *)
  let _ = ensure_sender_is_checker () in
  if is_burrow_done_with_liquidations auctions burrow_id
  then (([]: LigoOp.operation list), auctions)
  else (Ligo.failwith error_BurrowHasCompletedLiquidation : LigoOp.operation list * liquidation_auctions)

let[@inline] send_slice_to_auction (auctions: liquidation_auctions) (slice: liquidation_slice_contents) : LigoOp.operation list * liquidation_auctions =
  assert (!Ligo.Tezos.self_address = auctions_public_address); (* ENSURE IT's CALLED IN THE RIGHT CONTEXT. *)
  let _ = ensure_sender_is_checker () in
  let ops = ([]: LigoOp.operation list) in
  let auctions = liquidation_auction_send_to_auction auctions slice in
  (ops, auctions)

(** Cancel the liquidation of a slice. This is only half the story: after we
  * perform all changes on the liquidation auction side, we have to pass the
  * remaining data to checker to perform the rest of the changes. *)
let[@inline] liquidation_auction_cancel_liquidation_slice (auctions: liquidation_auctions) (permission: permission) (leaf_ptr: leaf_ptr) : (LigoOp.operation list * liquidation_auctions) =
  assert (!Ligo.Tezos.self_address = auctions_public_address); (* ENSURE IT's CALLED IN THE RIGHT CONTEXT. *)
  let _ = ensure_no_tez_given () in
  let (cancelled, auctions) = liquidation_auctions_cancel_slice auctions leaf_ptr in
  let op = match (LigoOp.Tezos.get_entrypoint_opt "%cancelSliceLiquidation" checker_public_address : (permission * liquidation_slice_contents) LigoOp.contract option) with
    | Some c -> LigoOp.Tezos.permission_slice_transaction (permission, cancelled) (Ligo.tez_from_literal "0mutez") c
    | None -> (Ligo.failwith error_GetEntrypointOptFailureCancelSliceLiquidation : LigoOp.operation) in
  ([op], auctions)

let touch_liquidation_slice
    (ops: LigoOp.operation list)
    (auctions: liquidation_auctions)
    (leaf_ptr: leaf_ptr)
  : (LigoOp.operation list * liquidation_auctions * return_kit_data * kit) =

  let slice, outcome, auctions = liquidation_auctions_pop_completed_slice auctions leaf_ptr in

  (* How much kit should be given to the burrow and how much should be burned. *)
  (* FIXME: we treat each slice in a lot separately, so Sum(kit_to_repay_i +
   * kit_to_burn_i)_{1..n} might not add up to outcome.winning_bid.kit, due
   * to truncation. That could be a problem; the extra kit, no matter how
   * small, must be dealt with (e.g. be removed from the circulating kit).
   *
   *   kit_corresponding_to_slice =
   *     FLOOR (outcome.winning_bid.kit * (leaf.tez / outcome.sold_tez))
   *   penalty =
   *     CEIL (kit_corresponding_to_slice * penalty_percentage)  , if (corresponding_kit < leaf.min_kit_for_unwarranted)
   *     zero                                                    , otherwise
   *   kit_to_repay = kit_corresponding_to_slice - penalty
  *)
  let kit_to_repay, kit_to_burn =
    let corresponding_kit =
      kit_of_fraction_floor
        (Ligo.mul_int_int (tez_to_mutez slice.tez) (kit_to_mukit_int outcome.winning_bid.kit))
        (Ligo.mul_int_int (tez_to_mutez outcome.sold_tez) kit_scaling_factor_int)
    in
    let penalty =
      let { num = num_lp; den = den_lp; } = liquidation_penalty in
      if corresponding_kit < slice.min_kit_for_unwarranted then
        kit_of_fraction_ceil
          (Ligo.mul_int_int (kit_to_mukit_int corresponding_kit) num_lp)
          (Ligo.mul_int_int kit_scaling_factor_int den_lp)
      else
        kit_zero
    in
    (kit_sub corresponding_kit penalty, penalty)
  in

  (* Signal the burrow to send the tez to checker. *)
  let op = match (LigoOp.Tezos.get_entrypoint_opt "%burrowSendSliceToChecker" slice.burrow : Ligo.tez LigoOp.contract option) with
    | Some c -> LigoOp.Tezos.tez_transaction slice.tez (Ligo.tez_from_literal "0mutez") c
    | None -> (Ligo.failwith error_GetEntrypointOptFailureBurrowSendSliceToChecker : LigoOp.operation) in
  ((op :: ops), auctions, (slice, kit_to_repay), kit_to_burn)

let rec touch_liquidation_slices_rec
    (ops, state_liquidation_auctions, ds, old_kit_to_burn, slices: LigoOp.operation list * liquidation_auctions * return_kit_data list * kit * leaf_ptr list)
  : (LigoOp.operation list * liquidation_auctions * return_kit_data list * kit) =
  match slices with
  | [] -> (ops, state_liquidation_auctions, ds, old_kit_to_burn)
  | x::xs ->
    let new_ops, new_state_liquidation_auctions, d, new_kit_to_burn =
      touch_liquidation_slice ops state_liquidation_auctions x in
    touch_liquidation_slices_rec (new_ops, new_state_liquidation_auctions, (d::ds), kit_add old_kit_to_burn new_kit_to_burn, xs)

(** Touch some liquidation slices. This is only half the story: after we
  * perform all changes on the liquidation auction side, we have to pass the
  * relevant data to checker so that it can (a) update the affected burrows,
  * and (b) burn the necessary kit. *)
(* FIXME: I don't think we should allow this list to be "too long". After
 * all, it's a user that chooses it, and the user can always be malicious. *)
let[@inline] liquidation_auction_touch_liquidation_slices (auctions: liquidation_auctions) (slices: leaf_ptr list) : (LigoOp.operation list * liquidation_auctions) =
  assert (!Ligo.Tezos.self_address = auctions_public_address); (* ENSURE IT's CALLED IN THE RIGHT CONTEXT. *)
  let _ = ensure_no_tez_given () in
  (* NOTE: the order of the operations is reversed here (wrt to the order of
   * the slices), but hopefully we don't care in this instance about this. *)
  let ops, auctions, ds, kit_to_burn =
    touch_liquidation_slices_rec (([]: LigoOp.operation list), auctions, ([]: return_kit_data list), kit_zero, slices) in
  let op = match (LigoOp.Tezos.get_entrypoint_opt "%touchLiquidationSlices" checker_public_address : tls_data LigoOp.contract option) with
    | Some c -> LigoOp.Tezos.tls_data_transaction (ds, kit_to_burn) (Ligo.tez_from_literal "0mutez") c
    | None -> (Ligo.failwith error_GetEntrypointOptFailureTouchLiquidationSlices : LigoOp.operation) in
  (* FIXME: assert_checker_invariants new_state; *)
  (* FIXME: the op should actually be AT THE END OF THE LIST. *)
  ((op :: ops), auctions)

let rec touch_oldest_rec
    (ops, state_liquidation_auctions, ds, old_kit_to_burn, maximum: LigoOp.operation list * liquidation_auctions * return_kit_data list * kit * int)
  : (LigoOp.operation list * liquidation_auctions * return_kit_data list * kit) =
  if maximum <= 0 then
    (ops, state_liquidation_auctions, ds, old_kit_to_burn)
  else
    match liquidation_auction_oldest_completed_liquidation_slice state_liquidation_auctions with
    | None -> (ops, state_liquidation_auctions, ds, old_kit_to_burn)
    | Some leaf ->
      let new_ops, new_state_liquidation_auctions, d, new_kit_to_burn =
        touch_liquidation_slice ops state_liquidation_auctions leaf in
      touch_oldest_rec (new_ops, new_state_liquidation_auctions, (d::ds), kit_add old_kit_to_burn new_kit_to_burn, maximum - 1)

let[@inline] liquidation_auction_touch_oldest_slices (auctions: liquidation_auctions) : (LigoOp.operation list * liquidation_auctions) =
  assert (!Ligo.Tezos.self_address = auctions_public_address); (* ENSURE IT's CALLED IN THE RIGHT CONTEXT. *)
  let _ = ensure_sender_is_checker () in
  (* TODO: Figure out how many slices we can process per checker touch.*)
  let ops, auctions, ds, kit_to_burn =
    touch_oldest_rec (([]: LigoOp.operation list), auctions, ([]: return_kit_data list), kit_zero, number_of_slices_to_process) in
  let op = match (LigoOp.Tezos.get_entrypoint_opt "%touchLiquidationSlices" checker_public_address : tls_data LigoOp.contract option) with
    | Some c -> LigoOp.Tezos.tls_data_transaction (ds, kit_to_burn) (Ligo.tez_from_literal "0mutez") c
    | None -> (Ligo.failwith error_GetEntrypointOptFailureTouchLiquidationSlices : LigoOp.operation) in
  (* FIXME: assert_checker_invariants new_state; *)
  (* FIXME: the op should actually be AT THE END OF THE LIST. *)
  ((op :: ops), auctions)

(* ************************************************************************* *)
(**                          LIQUIDATION AUCTIONS                            *)
(* ************************************************************************* *)

(** Bid in current liquidation auction. Fail if the auction is closed, or if the bid is
  * too low. If successful, return a ticket which can be used to
  * reclaim the kit when outbid. *)
let[@inline] liquidation_auction_place_bid (auctions: liquidation_auctions) (kit: kit_token) : LigoOp.operation list * liquidation_auctions =
  assert (!Ligo.Tezos.self_address = auctions_public_address); (* ENSURE IT's CALLED IN THE RIGHT CONTEXT. *)
  let _ = ensure_no_tez_given () in
  let kit = ensure_valid_kit_token kit in (* destroyed *)

  let bid = { address=(!Ligo.Tezos.sender); kit=kit; } in
  let current_auction = liquidation_auction_get_current_auction auctions in

  let (new_current_auction, bid_details) = place_liquidation_auction_bid current_auction bid in
  let bid_ticket = issue_liquidation_auction_bid_ticket bid_details in
  let op = match (LigoOp.Tezos.get_entrypoint_opt "%transferLABidTicket" !Ligo.Tezos.sender : liquidation_auction_bid_content Ligo.ticket LigoOp.contract option) with
    | Some c -> LigoOp.Tezos.la_bid_transaction bid_ticket (Ligo.tez_from_literal "0mutez") c
    | None -> (Ligo.failwith error_GetEntrypointOptFailureTransferLABidTicket : LigoOp.operation) in
  let auctions = { auctions with current_auction = Some new_current_auction; } in
  ([op], auctions)

(** Reclaim a failed bid for the current or a completed liquidation auction. *)
let[@inline] liquidation_auction_reclaim_bid (auctions: liquidation_auctions) (bid_ticket: liquidation_auction_bid_ticket) : LigoOp.operation list * liquidation_auctions =
  assert (!Ligo.Tezos.self_address = auctions_public_address); (* ENSURE IT's CALLED IN THE RIGHT CONTEXT. *)
  let _ = ensure_no_tez_given () in
  let bid_details = ensure_valid_liquidation_auction_bid_ticket bid_ticket in
  let kit = reclaim_liquidation_auction_bid auctions bid_details in
  (* FIXME: this cannot work correctly while in a contract that is not checker.
   * Changing the bid to include the kit tokens seems pretty hard (the bid
   * itself is also a ticket, and the kit is burried deep into the bid
   * representation). The easiest way out of this situation would be to have a
   * checker entrypoint to issue and send kit to people and invoke that. *)
  let kit_tokens = kit_issue kit in
  let op = match (LigoOp.Tezos.get_entrypoint_opt "%transferKit" !Ligo.Tezos.sender : kit_token LigoOp.contract option) with
    | Some c -> LigoOp.Tezos.kit_token_transaction kit_tokens (Ligo.tez_from_literal "0mutez") c
    | None -> (Ligo.failwith error_GetEntrypointOptFailureTransferKit : LigoOp.operation) in
  ([op], auctions) (* FIXME: unchanged state. It's a little weird that we don't keep track of how much kit has not been reclaimed. *)

(** Reclaim a winning bid for the current or a completed liquidation auction. *)
let[@inline] liquidation_auction_reclaim_winning_bid (auctions: liquidation_auctions) (bid_ticket: liquidation_auction_bid_ticket) : LigoOp.operation list * liquidation_auctions =
  assert (!Ligo.Tezos.self_address = auctions_public_address); (* ENSURE IT's CALLED IN THE RIGHT CONTEXT. *)
  let _ = ensure_no_tez_given () in
  let bid_details = ensure_valid_liquidation_auction_bid_ticket bid_ticket in
  let (tez, auctions) = reclaim_liquidation_auction_winning_bid auctions bid_details in
  let op = match (LigoOp.Tezos.get_contract_opt !Ligo.Tezos.sender : unit LigoOp.contract option) with
    | Some c -> LigoOp.Tezos.unit_transaction () tez c
    | None -> (Ligo.failwith error_GetContractOptFailure : LigoOp.operation) in
  ([op], auctions)

(* TODO: Maybe we should provide an entrypoint for increasing a losing bid.
 * *)

(* (\** Increase a failed bid for the current auction. *\)
 * val increase_bid : checker -> address:Ligo.address -> increase:kit -> bid_ticket:liquidation_auction_bid_ticket
 *   -> liquidation_auction_bid_ticket *)

(* ************************************************************************* *)
(*                                CONTRACT                                   *)
(* ************************************************************************* *)

(* initial storage: liquidation_auction_empty
 * invariants for storage: assert_liquidation_auction_invariants
 *)

type auction_storage = liquidation_auctions

(* ENTRYPOINTS *)

type auction_params =
  (* Touch the liquidation auctions contract (e.g. start/finish auctions. *)
  | LiqAuctionTouch of ratio (* starting price *)
  (* Ensure that a burrow has no unclaimed slices: should only be invokable by checker. *)
  | EnsureNoUnclaimedSlices of Ligo.address
  (* Send a slice to liquidation: should only be invokable by checker. *)
  | SendSliceToAuction of liquidation_slice_contents
  (* Cancel the liquidation of a slice. *)
  | CancelLiquidationOfSlice of (permission * leaf_ptr)
  (* Touch a few liquidation slices *)
  | LiqAuctionTouchSlices of (leaf_ptr list)
  (* Touch the oldest X liquidation slices *)
  | LiqAuctionTouchOldestSlices
  (* Liquidation Auction *)
  | LiqAuctionPlaceBid of kit_token
  | LiqAuctionReclaimBid of liquidation_auction_bid_ticket
  | LiqAuctionReclaimWinningBid of liquidation_auction_bid_ticket

let liquidation_auction_main (op_and_state: auction_params * auction_storage) : LigoOp.operation list * auction_storage =
  let op, state = op_and_state in
  match op with
  (* Touch the liquidation auctions contract (e.g. start/finish auctions. *)
  | LiqAuctionTouch price ->
    liquidation_auction_touch state price
  (* Burrow operations *)
  | EnsureNoUnclaimedSlices burrow_id ->
    ensure_no_unclaimed_slices state burrow_id
  (* Mark burrow for liquidation *)
  | SendSliceToAuction slice ->
    send_slice_to_auction state slice
  (* Cancel the liquidation of a slice *)
  | CancelLiquidationOfSlice p ->
    let (permission, leaf_ptr) = p in
    liquidation_auction_cancel_liquidation_slice state permission leaf_ptr
  (* Touch a few liquidation slices *)
  | LiqAuctionTouchSlices leaf_ptr_list ->
    liquidation_auction_touch_liquidation_slices state leaf_ptr_list
  (* Touch the oldest X liquidation slices *)
  | LiqAuctionTouchOldestSlices (* no arguments *) ->
    liquidation_auction_touch_oldest_slices state
  (* Liquidation Auction *)
  | LiqAuctionPlaceBid kit_token ->
    liquidation_auction_place_bid state kit_token
  | LiqAuctionReclaimBid ticket ->
    liquidation_auction_reclaim_bid state ticket
  | LiqAuctionReclaimWinningBid ticket ->
    liquidation_auction_reclaim_winning_bid state ticket
